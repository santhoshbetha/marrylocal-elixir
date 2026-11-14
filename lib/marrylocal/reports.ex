defmodule Marrylocal.Reports do
  @moduledoc """
  Member safety reports and the administrative moderation queue.

  Rules:

    * a member cannot report themselves;
    * a reporter may have at most one open (`pending`) report per member;
    * a reporter is limited to five reports per rolling 24 hours;
    * resolved and dismissed rows are retained permanently for audit.
  """

  import Ecto.Query, warn: false

  alias Marrylocal.Accounts.User
  alias Marrylocal.Repo
  alias Marrylocal.Reports.UserReport

  @max_reports_per_day 5
  @review_statuses ~w(reviewed_action_taken dismissed)

  @doc "Files one report. Returns `{:ok, report}` or a stable error atom."
  def create_report(%User{} = reporter, attrs) when is_map(attrs) do
    reported_user_id = normalize_id(fetch(attrs, "reported_user_id"))
    reason = normalize_string(fetch(attrs, "reason"))
    details = normalize_string(fetch(attrs, "details"))

    cond do
      is_nil(reported_user_id) ->
        {:error, :invalid_user}

      reported_user_id == reporter.id ->
        {:error, :self_report}

      is_nil(reason) or reason not in UserReport.reasons() ->
        {:error, :invalid_reason}

      is_nil(Repo.get(User, reported_user_id)) ->
        {:error, :invalid_user}

      true ->
        with :ok <- check_rate_limit(reporter.id),
             :ok <- check_duplicate(reporter.id, reported_user_id),
             {:ok, report} <- insert_report(reporter.id, reported_user_id, reason, details) do
          {:ok, report}
        end
    end
  end

  @doc "Returns `{report, total_reports_against_reported_user}` rows for the queue."
  def list_reports(params \\ %{}) when is_map(params) do
    case requested_status(params["status"]) do
      nil ->
        {:error, :invalid_status}

      status ->
        reports =
          UserReport
          |> where([r], r.status == ^status)
          |> order_by([r], desc: r.inserted_at, desc: r.id)
          |> preload([:reporter, :reported_user])
          |> Repo.all()

        counts =
          reports
          |> Enum.map(& &1.reported_user_id)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> report_counts()

        {:ok,
         Enum.map(reports, fn report ->
           {report, Map.get(counts, report.reported_user_id, 0)}
         end)}
    end
  end

  def get_report(id) do
    case normalize_id(id) do
      nil ->
        nil

      report_id ->
        UserReport
        |> Repo.get(report_id)
        |> case do
          nil -> nil
          report -> Repo.preload(report, [:reporter, :reported_user])
        end
    end
  end

  @doc "Marks a pending report resolved or dismissed, optionally suspending the member."
  def review_report(%UserReport{} = report, %User{} = admin, attrs) when is_map(attrs) do
    status = normalize_string(fetch(attrs, "status"))
    suspend? = truthy?(fetch(attrs, "suspend_user"))
    notes = normalize_string(fetch(attrs, "admin_notes"))
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    cond do
      report.status != "pending" ->
        {:error, :already_reviewed}

      status not in @review_statuses ->
        {:error, :invalid_status}

      true ->
        result =
          Repo.transaction(fn ->
            with {:ok, updated} <-
                   report
                   |> Ecto.Changeset.change(
                     status: status,
                     reviewed_by_admin_id: admin.id,
                     reviewed_at: now,
                     admin_notes: notes
                   )
                   |> Repo.update(),
                 :ok <- maybe_suspend(report.reported_user_id, suspend?) do
              Repo.preload(updated, [:reporter, :reported_user], force: true)
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

        result
    end
  end

  @doc "Returns historical reports filed against one member, newest first."
  def reports_against_user(user_id, limit \\ 20) do
    UserReport
    |> where([r], r.reported_user_id == ^user_id)
    |> order_by([r], desc: r.inserted_at)
    |> limit(^limit)
    |> preload([:reporter])
    |> Repo.all()
  end

  def report_counts([]), do: %{}

  def report_counts(user_ids) when is_list(user_ids) do
    from(r in UserReport,
      where: r.reported_user_id in ^user_ids,
      group_by: r.reported_user_id,
      select: {r.reported_user_id, count(r.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp insert_report(reporter_id, reported_user_id, reason, details) do
    %UserReport{}
    |> UserReport.changeset(%{
      reporter_id: reporter_id,
      reported_user_id: reported_user_id,
      reason: reason,
      details: details,
      status: "pending"
    })
    |> Repo.insert()
    |> case do
      {:ok, report} ->
        {:ok, Repo.preload(report, [:reporter, :reported_user], force: true)}

      {:error, %Ecto.Changeset{} = changeset} ->
        if changeset.errors[:reporter_id] || changeset.errors[:reported_user_id] do
          {:error, :duplicate_pending}
        else
          {:error, changeset}
        end
    end
  end

  defp check_rate_limit(reporter_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -24 * 60 * 60, :second)

    count =
      from(r in UserReport,
        where: r.reporter_id == ^reporter_id and r.inserted_at >= ^cutoff
      )
      |> Repo.aggregate(:count, :id)

    if count >= @max_reports_per_day, do: {:error, :rate_limited}, else: :ok
  end

  defp check_duplicate(reporter_id, reported_user_id) do
    exists? =
      Repo.exists?(
        from r in UserReport,
          where:
            r.reporter_id == ^reporter_id and r.reported_user_id == ^reported_user_id and
              r.status == "pending"
      )

    if exists?, do: {:error, :duplicate_pending}, else: :ok
  end

  defp maybe_suspend(_user_id, false), do: :ok

  defp maybe_suspend(user_id, true) do
    case Repo.get(User, user_id) do
      nil ->
        {:error, :reported_user_not_found}

      user ->
        user
        |> Ecto.Changeset.change(user_state: :inactive)
        |> Repo.update()
        |> case do
          {:ok, _user} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp requested_status(nil), do: "pending"
  defp requested_status(""), do: "pending"

  defp requested_status(status) when is_binary(status) do
    normalized = status |> String.trim() |> String.downcase()
    if normalized in UserReport.statuses(), do: normalized
  end

  defp requested_status(_status), do: nil

  defp fetch(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))

  defp normalize_id(value) when is_integer(value), do: value

  defp normalize_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp normalize_id(_value), do: nil

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp truthy?(value) when value in [true, 1, "1", "true", "TRUE"], do: true
  defp truthy?(_value), do: false
end

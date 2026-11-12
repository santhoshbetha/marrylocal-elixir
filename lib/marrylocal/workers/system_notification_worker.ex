defmodule Marrylocal.Workers.SystemNotificationWorker do
  @moduledoc """
  Inserts and live-broadcasts a system notification for a targeted audience.

  Rows are written with `Repo.insert_all/3` in batches of 500 and pushed to each
  online user's `user_notifications:<id>` topic immediately after the insert.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Marrylocal.Admin.Audience
  alias Marrylocal.Notifications.Notification
  alias Marrylocal.Repo
  alias MarrylocalWeb.Endpoint

  @batch_size 500

  @doc "Counts the audience for a broadcast without writing anything."
  def count_recipients(args) when is_map(args) do
    Audience.count(args)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"title" => title, "body" => body} = args})
      when is_binary(title) and is_binary(body) and title != "" and body != "" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _result} =
      Repo.transaction(fn ->
        Audience.query(args)
        |> Repo.stream(max_rows: @batch_size)
        |> Stream.chunk_every(@batch_size)
        |> Enum.each(&insert_and_broadcast(&1, title, body, now))
      end)

    :ok
  rescue
    error ->
      Logger.error("System notification broadcast failed: #{Exception.message(error)}")
      {:error, error}
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("SystemNotificationWorker received an invalid payload: #{inspect(args)}")
    {:cancel, :invalid_args}
  end

  defp insert_and_broadcast([], _title, _body, _now), do: :ok

  defp insert_and_broadcast(users, title, body, now) do
    rows =
      Enum.map(users, fn user ->
        %{
          user_id: user.id,
          type: :system,
          title: title,
          body: body,
          is_read: false,
          metadata: %{},
          inserted_at: now,
          updated_at: now
        }
      end)

    {_count, inserted} =
      Repo.insert_all(Notification, rows, returning: [:id, :user_id])

    Enum.each(inserted, fn %{id: id, user_id: user_id} ->
      broadcast(user_id, %{
        id: id,
        type: "system",
        title: title,
        body: body,
        is_read: false,
        metadata: %{},
        actor_id: nil,
        inserted_at: now
      })
    end)
  end

  defp broadcast(user_id, payload) do
    Endpoint.broadcast!("user_notifications:#{user_id}", "new_notification", payload)
  rescue
    error ->
      Logger.warning(
        "Could not broadcast system notification to user #{user_id}: #{Exception.message(error)}"
      )

      :error
  end
end

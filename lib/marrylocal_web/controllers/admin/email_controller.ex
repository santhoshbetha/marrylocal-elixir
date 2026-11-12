defmodule MarrylocalWeb.Admin.EmailController do
  @moduledoc """
  Queues administrative broadcasts in Resend-safe batches.

  Manual mode accepts explicit addresses; location mode resolves verified active
  users on the server so the browser never has to download a recipient list.
  """

  use MarrylocalWeb, :controller

  require Logger

  alias Marrylocal.Admin.Audience
  alias Marrylocal.Workers.BulkEmailWorker

  @email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/
  @batch_size 25
  @genders ~w(All Male Female)

  @doc """
  `POST /api/v1/admin/emails/bulk-send`

  Body examples:

      {"mode": "manual", "emails": ["a@example.com"], "subject": "Hi", "content": "<p>Hello</p>"}

      {"mode": "location", "state": "Delhi", "city": "Delhi", "gender": "Female",
       "subject": "Hi", "content": "<p>Hello</p>"}
  """
  def bulk_send(conn, params) do
    with {:ok, subject} <- validate_text(params["subject"], "subject", 200),
         {:ok, content} <- validate_text(params["content"], "content", 20_000),
         {:ok, gender} <- validate_gender(params["gender"]),
         {:ok, mode} <- validate_mode(params["mode"] || infer_mode(params)),
         {:ok, emails} <- resolve_recipients(mode, params, gender) do
      enqueue_batches(conn, emails, subject, content)
    else
      {:error, message} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", error: message})
    end
  end

  @doc """
  `GET /api/v1/admin/emails/preview-count`

  Returns the exact number of addresses that would be queued.
  """
  def preview_count(conn, params) do
    with {:ok, gender} <- validate_gender(params["gender"]),
         {:ok, mode} <- validate_mode(params["mode"] || infer_mode(params)) do
      count =
        case mode do
          "manual" ->
            case parse_emails(params["emails"]) do
              [] -> 0
              emails -> length(resolve_manual(emails, gender))
            end

          "location" ->
            length(
              Audience.emails(%{
                "target_type" => "location",
                "state" => params["state"],
                "city" => params["city"],
                "gender" => gender,
                "verified_only" => true
              })
            )
        end

      conn
      |> put_status(:ok)
      |> json(%{status: "success", recipient_count: count})
    else
      {:error, message} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", error: message})
    end
  end

  defp enqueue_batches(conn, emails, subject, content) do
    result =
      emails
      |> Enum.chunk_every(@batch_size)
      |> Enum.reduce_while(:ok, fn batch, :ok ->
        job = BulkEmailWorker.new(%{emails: batch, subject: subject, content: content})

        case Oban.insert(job) do
          {:ok, _job} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      :ok ->
        conn
        |> put_status(:accepted)
        |> json(%{status: "queued", queued_count: length(emails)})

      {:error, reason} ->
        Logger.error("Could not enqueue bulk email jobs: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{status: "error", error: "Could not queue the email broadcast"})
    end
  end

  defp resolve_recipients("manual", params, gender) do
    emails = parse_emails(params["emails"])

    cond do
      emails == [] ->
        {:error, "emails must contain at least one valid address"}

      true ->
        resolved = resolve_manual(emails, gender)

        if resolved == [] do
          {:error, "no registered recipients matched the selected gender"}
        else
          {:ok, resolved}
        end
    end
  end

  defp resolve_recipients("location", params, gender) do
    emails =
      Audience.emails(%{
        "target_type" => "location",
        "state" => params["state"],
        "city" => params["city"],
        "gender" => gender,
        "verified_only" => true
      })

    if emails == [] do
      {:error, "no verified recipients matched the selected location"}
    else
      {:ok, emails}
    end
  end

  defp resolve_manual(emails, "All"), do: emails

  defp resolve_manual(emails, gender) do
    Audience.emails(%{
      "target_type" => "individual",
      "identifiers" => emails,
      "gender" => gender
    })
  end

  defp infer_mode(params) do
    if is_list(params["emails"]) or is_binary(params["emails"]), do: "manual", else: "location"
  end

  defp validate_mode(mode) when mode in ["manual", "location"], do: {:ok, mode}
  defp validate_mode(_mode), do: {:error, "mode must be manual or location"}

  defp validate_gender(nil), do: {:ok, "All"}

  defp validate_gender(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:ok, "All"}
      trimmed in @genders -> {:ok, trimmed}
      true -> {:error, "gender must be All, Male, or Female"}
    end
  end

  defp validate_gender(_value), do: {:error, "gender must be All, Male, or Female"}

  defp parse_emails(emails) when is_list(emails) do
    emails
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&String.split(&1, [";", ","], trim: true))
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(@email_regex, &1))
    |> Enum.uniq()
  end

  defp parse_emails(emails) when is_binary(emails) do
    emails
    |> String.split([";", ","], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(@email_regex, &1))
    |> Enum.uniq()
  end

  defp parse_emails(_emails), do: []

  defp validate_text(value, field, max_length) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:error, "#{field} cannot be blank"}
      String.length(trimmed) > max_length -> {:error, "#{field} is too long"}
      true -> {:ok, trimmed}
    end
  end

  defp validate_text(_value, field, _max_length), do: {:error, "#{field} is required"}
end

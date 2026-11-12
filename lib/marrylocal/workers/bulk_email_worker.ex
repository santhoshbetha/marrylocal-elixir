defmodule Marrylocal.Workers.BulkEmailWorker do
  @moduledoc """
  Delivers administrative broadcast emails in small batches.

  The job payload is intentionally plain JSON so Oban persists it in Postgres and
  the work survives restarts. Batches are spaced out to stay comfortably below
  Resend's per-second API limits, and a single failed recipient never aborts the
  rest of the broadcast.
  """

  use Oban.Worker, queue: :mailers, max_attempts: 3

  require Logger

  import Swoosh.Email

  alias Marrylocal.Mailer

  @batch_size 25
  @batch_delay_ms 250
  @from {"MarryLocal", "noreply@marrylocal.in"}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"emails" => emails, "subject" => subject, "content" => content}
      })
      when is_list(emails) and is_binary(subject) and is_binary(content) do
    emails
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.chunk_every(@batch_size)
    |> Enum.with_index()
    |> Enum.each(fn {batch, index} ->
      if index > 0, do: Process.sleep(@batch_delay_ms)
      Enum.each(batch, &deliver(&1, subject, content))
    end)

    :ok
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("BulkEmailWorker received an invalid payload: #{inspect(args)}")
    {:cancel, :invalid_args}
  end

  defp deliver(recipient, subject, content) do
    email =
      new()
      |> to(recipient)
      |> from(@from)
      |> subject(subject)
      |> html_body(content)

    case Mailer.deliver(email) do
      {:ok, _metadata} ->
        :ok

      {:error, reason} ->
        Logger.error("Bulk email to #{recipient} failed: #{inspect(reason)}")
        :error
    end
  rescue
    exception ->
      Logger.error("Bulk email to #{recipient} raised: #{Exception.message(exception)}")
      :error
  catch
    kind, reason ->
      Logger.error("Bulk email to #{recipient} failed (#{kind}): #{inspect(reason)}")
      :error
  end
end

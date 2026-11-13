defmodule Marrylocal.Workers.DeleteR2ObjectWorker do
  @moduledoc """
  Deletes one Cloudflare R2 object outside the user-facing request path.

  Replaced avatars, gallery photos, rejected uploads, and reviewed KYC
  documents are enqueued here so a slow or failed R2 delete can never block an
  HTTP response. Oban retries transient storage failures.
  """

  use Oban.Worker, queue: :default, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"bucket" => bucket, "key" => key}})
      when is_binary(bucket) and bucket != "" and is_binary(key) and key != "" do
    case ExAws.S3.delete_object(bucket, key) |> ExAws.request() do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: {:cancel, :invalid_args}
end

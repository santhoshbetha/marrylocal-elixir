defmodule Marrylocal.Workers.R2Cleanup do
  use Oban.Worker, queue: :default
  alias ExAws.S3

  @bucket "marrylocal-images"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"shortid" => shortid}}) do
    prefix = "profiles/#{shortid}/"

    # 1. List all objects in the user's "folder"
    # S3 returns up to 1,000 objects per request
    S3.list_objects(@bucket, prefix: prefix)
    |> ExAws.request()
    |> case do
      {:ok, %{body: %{contents: []}}} ->
        # Folder already empty
        :ok

      {:ok, %{body: %{contents: objects}}} ->
        # 2. Extract keys and delete them in bulk
        keys = Enum.map(objects, & &1.key)

        S3.delete_multiple_objects(@bucket, keys)
        |> ExAws.request()

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end

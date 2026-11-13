defmodule Marrylocal.Uploaders.VerificationDocument do
  @moduledoc """
  Waffle uploader for private identity-verification document images.

  The stored value is the R2 object key. Files are private by default and are
  deleted immediately after an admin approval or rejection decision.
  """

  use Waffle.Definition
  use Waffle.Ecto.Definition

  @versions [:original]
  @allowed_extensions ~w(.png .jpg .jpeg .webp)
  @allowed_content_types ~w(image/png image/jpeg image/webp)

  def validate({file, _verification}) do
    extension = file.file_name |> Path.extname() |> String.downcase()
    content_type = Map.get(file, :content_type)

    extension in @allowed_extensions and
      (is_nil(content_type) or content_type in @allowed_content_types)
  end

  def bucket do
    configured =
      :marrylocal
      |> Application.get_env(:kyc, [])
      |> Keyword.get(:bucket)
      |> normalize_bucket()

    case configured || normalize_bucket(System.get_env("KYC_S3_BUCKET")) do
      value when is_binary(value) ->
        value

      _ ->
        if Application.get_env(:marrylocal, :env) == :prod do
          raise "KYC_S3_BUCKET must point to a private R2 bucket"
        else
          System.get_env("AWS_S3_BUCKET") || "marrylocal"
        end
    end
  end

  defp normalize_bucket(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_bucket(_value), do: nil

  def filename(version, {file, _verification}) do
    extension = file.file_name |> Path.extname() |> String.downcase()
    "#{version}-#{Ecto.UUID.generate()}#{extension}"
  end

  def storage_dir(_version, {_file, verification}) do
    "private_kyc/users/#{verification.user_id}/identity-verifications"
  end

  def s3_object_headers(_version, {file, _verification}) do
    [content_type: Map.get(file, :content_type) || MIME.from_path(file.file_name)]
  end

  @doc "Short-lived presigned GET URL for admin review previews."
  def presigned_url(path, expires_in \\ 300)

  def presigned_url(path, expires_in) when is_binary(path) and path != "" do
    key = String.trim_leading(path, "/")

    case ExAws.S3.presigned_url(:get, bucket(), key, expires_in: expires_in) do
      {:ok, url} -> {:ok, url}
      {:error, reason} -> {:error, reason}
    end
  end

  def presigned_url(_path, _expires_in), do: {:error, :missing_document}

  @doc "Deletes one stored document object from the configured R2 bucket."
  def delete_object(path) when is_binary(path) and path != "" do
    key = String.trim_leading(path, "/")

    case ExAws.S3.delete_object(bucket(), key) |> ExAws.request() do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def delete_object(_path), do: :ok
end

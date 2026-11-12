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
    System.get_env("AWS_S3_BUCKET") || "marrylocal"
  end

  def filename(version, {file, _verification}) do
    extension = file.file_name |> Path.extname() |> String.downcase()
    "#{version}-#{Ecto.UUID.generate()}#{extension}"
  end

  def storage_dir(_version, {_file, verification}) do
    "uploads/users/#{verification.user_id}/identity-verifications"
  end

  def s3_object_headers(_version, {file, _verification}) do
    [content_type: Map.get(file, :content_type) || MIME.from_path(file.file_name)]
  end

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

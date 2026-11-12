defmodule Marrylocal.Uploaders.Avatar do
  @moduledoc """
  Waffle uploader for MarryLocal profile avatars.

  Files are stored in Cloudflare R2 through the S3-compatible ExAws adapter.
  Only raster image types are accepted; SVG and arbitrary binaries are
  deliberately rejected before any storage request is made.
  """

  use Waffle.Definition
  use Waffle.Ecto.Definition

  # Upload inline rather than inside a linked Waffle Task. With async uploads, a
  # storage exception exits the request process before the controller's
  # try/rescue can convert it into JSON telemetry, which the browser surfaces as
  # a CORS failure.
  @async false

  @versions [:original]
  @allowed_extensions ~w(.png .jpg .jpeg)
  @allowed_content_types ~w(image/png image/jpeg)

  def validate({file, _user}) do
    extension = file.file_name |> Path.extname() |> String.downcase()
    content_type = Map.get(file, :content_type)

    extension in @allowed_extensions and
      (is_nil(content_type) or content_type in @allowed_content_types)
  end

  def bucket do
    System.get_env("AWS_S3_BUCKET") || "marrylocal"
  end

  # Waffle appends the source extension itself in
  # `Waffle.Definition.Versioning.resolve_file_name/3`, so this must return the
  # bare version name. Returning "original.png" here produced "original.png.png".
  def filename(version, {_file, _user}), do: to_string(version)

  def storage_dir(_version, {_file, user}) do
    "uploads/users/#{user.id}/avatar"
  end

  def default_url(_version, _user), do: "/images/default_avatar.png"

  def s3_object_headers(_version, {file, _user}) do
    [content_type: Map.get(file, :content_type) || MIME.from_path(file.file_name)]
  end
end

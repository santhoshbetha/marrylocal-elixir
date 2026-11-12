defmodule Marrylocal.Uploaders.ProfilePhoto do
  @moduledoc """
  Waffle uploader for the ten gallery photo slots.

  Each slot owns a distinct R2 prefix:

      uploads/users/<user_id>/photos/<slot_index>/original.<ext>

  The scope passed to `store/1` and `url/2` is
  `%{user_id: integer, slot_index: integer}`, so replacing slot 3 never
  overwrites slot 0 or the primary avatar.
  """

  use Waffle.Definition

  # Keep storage errors inside the request process so the controller can
  # convert them into JSON telemetry instead of a linked Task exit.
  @async false

  @versions [:original]
  @allowed_extensions ~w(.png .jpg .jpeg)
  @allowed_content_types ~w(image/png image/jpeg)

  def validate({file, _scope}) do
    extension = file.file_name |> Path.extname() |> String.downcase()
    content_type = Map.get(file, :content_type)

    extension in @allowed_extensions and
      (is_nil(content_type) or content_type in @allowed_content_types)
  end

  def bucket do
    System.get_env("AWS_S3_BUCKET") || "marrylocal"
  end

  # Waffle appends the source extension in `resolve_file_name/3`.
  def filename(version, _file_and_scope), do: to_string(version)

  def storage_dir(_version, {_file, %{user_id: user_id, slot_index: slot_index}})
      when is_integer(user_id) and is_integer(slot_index) do
    "uploads/users/#{user_id}/photos/#{slot_index}"
  end

  def default_url(_version, _scope), do: nil

  def s3_object_headers(_version, {file, _scope}) do
    [content_type: Map.get(file, :content_type) || MIME.from_path(file.file_name)]
  end
end

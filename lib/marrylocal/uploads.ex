defmodule Marrylocal.Uploads do
  @moduledoc """
  Shared validation for multipart uploads.

  `Plug.Upload` does not expose a size field, so the temporary multipart file is
  stat'ed after parsing. These limits are enforced independently of the browser
  so direct API clients cannot bypass the avatar/gallery/KYC caps.
  """

  def validate_size(%Plug.Upload{path: path}, max_bytes)
      when is_binary(path) and is_integer(max_bytes) and max_bytes > 0 do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size <= max_bytes -> :ok
      {:ok, %File.Stat{}} -> {:error, :file_too_large}
      # A missing temp file is left for Waffle/changeset validation so the
      # controller can emit its canonical invalid-image telemetry.
      {:error, _reason} -> :ok
    end
  end

  def validate_size(_upload, _max_bytes), do: {:error, :invalid_upload}
end

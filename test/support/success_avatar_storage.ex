defmodule Marrylocal.TestSupport.SuccessAvatarStorage do
  @moduledoc """
  Test-only Waffle storage adapter that succeeds without network access.

  `put/3` returns the Waffle-resolved file name, while `url/4` delegates to the
  real S3 URL builder (which only reads configuration) so controller tests can
  assert the public avatar URL shape.
  """

  def put(_definition, _version, {file, _scope}), do: {:ok, file.file_name}

  defdelegate delete(definition, version, file_and_scope), to: Waffle.Storage.S3

  defdelegate url(definition, version, file_and_scope, options), to: Waffle.Storage.S3
end

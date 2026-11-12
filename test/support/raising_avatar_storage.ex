defmodule Marrylocal.TestSupport.RaisingAvatarStorage do
  @moduledoc """
  Test-only Waffle storage adapter that raises so the controller's rescue
  telemetry path can be exercised without network access.

  The simulated HTTP status is read from the application environment so tests
  can exercise both the 403 (credentials/policy) and 404 (endpoint/bucket
  routing) diagnostic branches.
  """

  alias Marrylocal.TestSupport.StorageHTTPError

  def put(_definition, _version, {_file, _scope}) do
    status = Application.get_env(:marrylocal, :test_storage_status, 403)

    raise StorageHTTPError,
      message: "simulated R2 bucket access denied (status #{status})",
      status: status
  end
end

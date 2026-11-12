defmodule Marrylocal.TestSupport.StorageHTTPError do
  @moduledoc """
  Test-only exception that mimics the HTTP status metadata an R2 failure carries.
  """

  defexception [:message, :status]
end

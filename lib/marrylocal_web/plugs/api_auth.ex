defmodule MarrylocalWeb.ApiAuth do
  @moduledoc """
  Compatibility wrapper around the stateless API plugs in `MarrylocalWeb.UserAuth`.

  New routes should compose `fetch_current_user/2` and
  `require_authenticated_api_user/2` in the router. This module remains for
  older scopes that expect a single halting plug.
  """

  import Plug.Conn

  alias MarrylocalWeb.UserAuth

  def init(opts), do: opts

  @doc """
  Fetches and enforces the bearer user. Halts with 401 when the token is
  missing, malformed, expired, or revoked.
  """
  def fetch_api_user(conn, _opts) do
    conn = UserAuth.fetch_current_user(conn, [])

    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_status(:unauthorized)
      |> Phoenix.Controller.json(%{status: "error", message: "Invalid or expired token"})
      |> halt()
    end
  end
end

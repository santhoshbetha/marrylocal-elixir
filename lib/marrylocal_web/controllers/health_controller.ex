defmodule MarrylocalWeb.HealthController do
  @moduledoc """
  Public readiness endpoint used by Kamal Proxy and other orchestrators.

  Kamal only routes live traffic to a new container after this check returns
  `200`. The endpoint verifies that Phoenix is accepting requests and that the
  PostgreSQL pool can answer a trivial query.
  """

  use MarrylocalWeb, :controller

  def index(conn, _params) do
    case Ecto.Adapters.SQL.query(Marrylocal.Repo, "SELECT 1", []) do
      {:ok, _result} ->
        healthy(conn)

      {:error, _reason} ->
        unavailable(conn)
    end
  rescue
    _error ->
      unavailable(conn)
  end

  defp healthy(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(:ok)
    |> json(%{status: "ok", database: "connected"})
  end

  defp unavailable(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(:service_unavailable)
    |> json(%{status: "error", database: "unavailable"})
  end
end

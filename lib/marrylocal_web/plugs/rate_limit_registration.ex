defmodule MarrylocalWeb.Plugs.RateLimitRegistration do
  @moduledoc """
  Limits each source IP to three registration attempts per 24 hours.

  The limiter is process-local Hammer/ETS, matching the existing discovery
  limiter. It is intentionally permissive enough for shared Indian mobile
  networks while still stopping scripted signup floods.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Marrylocal.RateLimit

  @limit 3
  @window_ms 24 * 60 * 60 * 1000

  def init(opts), do: opts

  def call(conn, _opts) do
    if local_development_ip?(conn.remote_ip) do
      conn
    else
      enforce(conn)
    end
  end

  defp enforce(conn) do
    key = "register:ip:#{ip_string(conn.remote_ip)}"

    case RateLimit.check_rate(key, @limit, @window_ms) do
      {:ok, false} ->
        conn

      {:ok, true} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{
          status: "error",
          code: "registration_rate_limited",
          message: "Too many signups from this network. Please try again tomorrow."
        })
        |> halt()
    end
  end

  # Local Playwright and development traffic all originates from loopback.
  # Production deployments never receive loopback client IPs, so the real limit
  # remains enforced there.
  defp local_development_ip?({127, 0, 0, 1}),
    do: Application.get_env(:marrylocal, :env) != :prod

  defp local_development_ip?({0, 0, 0, 0, 0, 0, 0, 1}),
    do: Application.get_env(:marrylocal, :env) != :prod

  defp local_development_ip?(_ip), do: false

  defp ip_string(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp ip_string(ip), do: to_string(ip)
end

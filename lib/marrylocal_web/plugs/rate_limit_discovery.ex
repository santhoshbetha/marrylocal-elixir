defmodule MarrylocalWeb.Plugs.RateLimitDiscovery do
  @moduledoc """
  Per-user rate limit for discovery searches.

  Authenticated users may issue 15 discovery requests in any 30-second window.
  The limiter is backed by the shared Hammer ETS table started in the
  application supervision tree.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Marrylocal.RateLimit

  @limit 15
  @window_ms 30_000

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      %{id: user_id} ->
        case RateLimit.check_rate(discovery_key(user_id), @limit, @window_ms) do
          {:ok, false} ->
            conn

          {:ok, true} ->
            conn
            |> put_status(:too_many_requests)
            |> json(%{
              status: "error",
              message: "Too many search requests. Please wait a moment before trying again."
            })
            |> halt()
        end

      _ ->
        conn
    end
  end

  defp discovery_key(user_id), do: "discovery:user:#{user_id}"
end

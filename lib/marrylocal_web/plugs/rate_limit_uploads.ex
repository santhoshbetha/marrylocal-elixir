defmodule MarrylocalWeb.Plugs.RateLimitUploads do
  @moduledoc """
  Per-user upload rate limit.

  The browser disables the upload button while a request is in flight, but the
  authenticated API can still be scripted. Ten uploads per minute per user keeps
  one account from exhausting temporary disk, DB pool connections, or R2
  bandwidth with parallel multipart requests.
  """

  import Plug.Conn

  alias Marrylocal.RateLimit

  @limit 10
  @window_ms 60_000

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      %{id: user_id} ->
        case RateLimit.check_rate("upload:user:#{user_id}", @limit, @window_ms) do
          {:ok, false} ->
            conn

          {:ok, true} ->
            conn
            |> put_status(:too_many_requests)
            |> Phoenix.Controller.json(%{
              status: "error",
              code: "upload_rate_limited",
              message: "Too many uploads. Please wait a minute and try again."
            })
            |> halt()
        end

      _ ->
        conn
    end
  end
end

defmodule MarrylocalWeb.Plugs.TrackUserActivity do
  @moduledoc """
  Refreshes `last_seen_at` for authenticated API traffic.

  Login time (`time_of_login` / `last_login_at`) is owned exclusively by the
  session controller. Presence is owned by `Phoenix.Presence`; this plug only
  maintains the durable activity heartbeat.
  """

  alias Marrylocal.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      %Marrylocal.Accounts.User{} = user -> Accounts.touch_last_seen(user)
      _ -> :ok
    end

    conn
  end
end

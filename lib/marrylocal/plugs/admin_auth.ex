defmodule MarrylocalWeb.Plugs.RequireAdmin do
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    # current_user is already assigned by your existing fetch_api_user plug
    user = conn.assigns[:current_user]

    if user && user.role == :admin do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "unauthorized", message: "Admin access required"})
      |> halt()
    end
  end
end

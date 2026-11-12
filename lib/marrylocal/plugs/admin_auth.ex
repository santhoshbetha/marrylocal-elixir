defmodule MarrylocalWeb.Plugs.RequireAdmin do
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    # `current_user` is already assigned by `:fetch_current_user`.
    user = conn.assigns[:current_user]

    if admin?(user) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "unauthorized", message: "Admin access required"})
      |> halt()
    end
  end

  defp admin?(%{role: role}), do: role in [:admin, "admin"]
  defp admin?(_user), do: false
end

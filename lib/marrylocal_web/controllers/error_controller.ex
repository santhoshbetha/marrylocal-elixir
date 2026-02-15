defmodule MarrylocalWeb.ErrorController do
  use MarrylocalWeb, :controller

  def not_found(conn, _params) do
    conn
    |> put_status(:not_found)
    |> put_view(MarrylocalWeb.ErrorJSON)
    |> render("404.json")
  end
end

defmodule MarrylocalWeb.MediaController do
  use MarrylocalWeb, :controller

  alias Marrylocal.Uploads.Media
  def delete(conn, %{"image_url" => image_url}) do
    user = conn.assigns.current_user

    if image_url in (user.images || []) do
      Media.delete_user_image(user, image_url)
      json(conn, %{message: "Image deleted successfully"})
    else
      conn |> put_status(:not_found) |> json(%{error: "Image not found in your profile"})
    end
  end
end

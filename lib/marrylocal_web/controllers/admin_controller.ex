defmodule MarrylocalWeb.AdminController do
  use MarrylocalWeb, :controller
  alias Marrylocal.Accounts
  alias Marrylocal.Admin
  alias Marrylocal.Admin.Stats
  alias Marrylocal.Repo

  def dashboard_stats(conn, _params) do
    json(conn, Stats.get_dashboard_counts())
  end

  def archived_users(conn, _params) do
    # Fetch from your soft-delete table
    archived = Repo.all(Marrylocal.DeletedUser)
    json(conn, %{data: archived})
  end

  # POST /api/admin/ban/:id
  def ban(conn, %{"id" => user_id, "reason" => reason}) do
    admin = conn.assigns.current_user

    with {:ok, target_user} <- Accounts.get_user_by_id(user_id),
         {:ok, _result} <- Admin.ban_user(admin, target_user, reason) do
      json(conn, %{message: "User #{target_user.shortid} has been banned and archived."})
    else
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "User not found"})

      {:error, _step, _failed_value, _changes} ->
        conn |> put_status(500) |> json(%{error: "Failed to process ban"})
    end
  end
end

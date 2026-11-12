defmodule MarrylocalWeb.NotificationsController do
  @moduledoc """
  REST inbox for the same notification rows pushed over `UserChannel`.
  """

  use MarrylocalWeb, :controller

  alias Marrylocal.Notifications

  @doc "GET /api/v1/notifications"
  def index(conn, params) do
    user = conn.assigns.current_user

    result =
      Notifications.list_notifications(user.id,
        page: params["page"],
        per_page: params["per_page"]
      )

    conn
    |> put_status(:ok)
    |> json(%{
      status: "success",
      data: %{
        notifications: Enum.map(result.notifications, &Notifications.payload/1),
        pagination: result.pagination,
        unread_count: result.unread_count
      }
    })
  end

  @doc "PATCH /api/v1/notifications/:id/read"
  def read(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, notification_id} <- parse_id(id),
         {:ok, notification} <- Notifications.mark_read(user.id, notification_id) do
      conn
      |> put_status(:ok)
      |> json(%{
        status: "success",
        data: %{
          notification: Notifications.payload(notification),
          unread_count: Notifications.unread_count(user.id)
        }
      })
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{status: "error", message: "Notification not found"})
    end
  end

  @doc "POST /api/v1/notifications/mark-all-read"
  def mark_all_read(conn, _params) do
    user = conn.assigns.current_user
    updated = Notifications.mark_all_read(user.id)

    conn
    |> put_status(:ok)
    |> json(%{
      status: "success",
      message: "All notifications marked as read",
      data: %{updated: updated, unread_count: 0}
    })
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_id(_id), do: :error
end

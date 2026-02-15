defmodule Marrylocal.Notifications do
  alias Marrylocal.{Repo, Accounts.User}

  def list_notifications(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, "User not found"}
      user -> {:ok, user.notifications || []}
    end
  end

  def mark_notification_as_read(user_id, notification_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, "User not found"}
      user ->
        notifications = user.notifications || []
        updated_notifications = Enum.map(notifications, fn notif ->
          if notif["id"] == notification_id do
            Map.put(notif, "read", true)
          else
            notif
          end
        end)

        changeset = Ecto.Changeset.change(user, notifications: updated_notifications)
        case Repo.update(changeset) do
          {:ok, _} -> {:ok, "Notification marked as read"}
          {:error, _} -> {:error, "Failed to update notifications"}
        end
    end
  end

  def send_channel_notification(user_id, title, body) do
    # This sends a message to the specific user's socket
    MarrylocalWeb.Endpoint.broadcast("notifications:#{user_id}", "new_msg", %{
      title: title,
      body: body,
      at: DateTime.utc_now()
    })
  end


end

defmodule Marrylocal.Workers.NotificationCleanupWorker do
  @moduledoc """
  Applies the notification retention policy once per day.

  Read activity notifications are removed after 30 days, unread activity after
  90 days, and system/admin notices after 365 days.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Marrylocal.Notifications

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    deleted = Notifications.delete_expired_notifications()

    Logger.info("Notification cleanup removed #{deleted} expired notification(s)")

    :ok
  end
end

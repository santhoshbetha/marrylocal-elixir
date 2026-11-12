defmodule Marrylocal.Notifications do
  @moduledoc """
  Per-user notification inbox and live push stream.

  Every read and write is scoped to the owning user. Notifications are written
  inside the same transaction as the relationship that produced them, then
  broadcast only after commit so a client can never receive a push for a row
  that does not exist.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Marrylocal.Notifications.Notification
  alias Marrylocal.Repo
  alias MarrylocalWeb.Endpoint

  @default_per_page 20
  @max_per_page 100
  @visible_types [:profile_like, :mutual_match, :system]

  def list_notifications(user_id, opts \\ [])

  def list_notifications(user_id, opts) when is_integer(user_id) or is_binary(user_id) do
    page = opts |> Keyword.get(:page, 1) |> normalize_positive(1)
    per_page = opts |> Keyword.get(:per_page, @default_per_page) |> normalize_per_page()

    base = visible_notifications(user_id)

    total = Repo.aggregate(base, :count, :id)

    notifications =
      base
      |> order_by([n], desc: n.inserted_at, desc: n.id)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    %{
      notifications: notifications,
      pagination: %{
        page: page,
        per_page: per_page,
        total: total,
        total_pages: total_pages(total, per_page)
      },
      unread_count: unread_count(user_id)
    }
  end

  def list_notifications(_user_id, _opts) do
    %{
      notifications: [],
      pagination: %{page: 1, per_page: @default_per_page, total: 0, total_pages: 0},
      unread_count: 0
    }
  end

  def mark_read(user_id, id) when is_integer(user_id) or is_binary(user_id) do
    case Repo.get_by(Notification, id: id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      %Notification{is_read: true} = notification ->
        {:ok, notification}

      %Notification{} = notification ->
        notification
        |> Ecto.Changeset.change(is_read: true, read_at: utc_now())
        |> Repo.update()
    end
  end

  def mark_read(_user_id, _id), do: {:error, :not_found}

  def mark_all_read(user_id) when is_integer(user_id) or is_binary(user_id) do
    now = utc_now()

    {updated, _rows} =
      Repo.update_all(
        from(n in Notification, where: n.user_id == ^user_id and n.is_read == false),
        set: [is_read: true, read_at: now, updated_at: now]
      )

    updated
  end

  def mark_all_read(_user_id), do: 0

  @doc """
  Deletes notifications past their retention window.

  * Read activity notifications expire 30 days after they were read.
  * Unread activity notifications expire 90 days after creation.
  * System and admin broadcasts are retained for 365 days.

  Legacy read rows with no `read_at` fall back to `updated_at`, so the first
  cleanup after the migration does not delete them prematurely.
  """
  def delete_expired_notifications(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)
    read_cutoff = DateTime.add(now, -30 * 86_400, :second)
    unread_cutoff = DateTime.add(now, -90 * 86_400, :second)
    long_lived_cutoff = DateTime.add(now, -365 * 86_400, :second)

    {long_lived, _} =
      Repo.delete_all(
        from(n in Notification,
          where: n.type in [:system, :admin_broadcast] and n.inserted_at < ^long_lived_cutoff
        )
      )

    {read_expired, _} =
      Repo.delete_all(
        from(n in Notification,
          where:
            n.type not in [:system, :admin_broadcast] and n.is_read == true and
              ((not is_nil(n.read_at) and n.read_at < ^read_cutoff) or
                 (is_nil(n.read_at) and n.updated_at < ^read_cutoff))
        )
      )

    {unread_expired, _} =
      Repo.delete_all(
        from(n in Notification,
          where:
            n.type not in [:system, :admin_broadcast] and n.is_read == false and
              n.inserted_at < ^unread_cutoff
        )
      )

    long_lived + read_expired + unread_expired
  end

  def unread_count(user_id) when is_integer(user_id) or is_binary(user_id) do
    visible_notifications(user_id)
    |> where([n], n.is_read == false)
    |> Repo.aggregate(:count, :id)
  end

  def unread_count(_user_id), do: 0

  defp visible_notifications(user_id) do
    from(n in Notification,
      where: n.user_id == ^user_id and n.type in ^@visible_types
    )
  end

  @doc """
  Inserts a notification and pushes it to the owner. Used for standalone writes;
  transaction-aware callers should use `insert_notification/1` and
  `broadcast_many/1` so the push happens after commit.
  """
  def create_notification(attrs) when is_map(attrs) do
    case insert_notification(attrs) do
      {:ok, notification} ->
        broadcast_many([notification])
        {:ok, notification}

      error ->
        error
    end
  end

  @doc "Builds and inserts one notification inside the caller's transaction."
  def insert_notification(attrs) when is_map(attrs) do
    %Notification{}
    |> Notification.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Pushes prepared rows after their transaction commits.

  A failed broadcast must never turn a committed relationship into an HTTP
  error, so delivery is best-effort and logged.
  """
  def broadcast_many(notifications) when is_list(notifications) do
    Enum.each(notifications, &broadcast_notification/1)
  end

  defp broadcast_notification(%Notification{} = notification) do
    Endpoint.broadcast!(
      "user_notifications:#{notification.user_id}",
      "new_notification",
      payload(notification)
    )
  rescue
    error ->
      Logger.warning(
        "Unable to broadcast notification #{notification.id}: #{Exception.message(error)}"
      )

      :error
  end

  @doc """
  Legacy channel broadcast used by the pre-migration nearby-user notify path.
  New code should use `create_notification/1`, which persists before pushing.
  """
  def send_channel_notification(user_id, title, body) do
    Endpoint.broadcast("notifications:#{user_id}", "new_msg", %{
      title: title,
      body: body,
      at: DateTime.utc_now()
    })
  end

  @doc "Serializes a notification for both REST responses and channel pushes."
  def payload(%Notification{} = notification) do
    %{
      id: notification.id,
      type: notification_type(notification.type),
      title: notification.title,
      body: notification.body,
      is_read: notification.is_read,
      read_at: notification.read_at,
      metadata: notification.metadata,
      actor_id: notification.actor_id,
      inserted_at: notification.inserted_at
    }
  end

  def payload(entry) when is_map(entry) do
    %{
      id: entry.id,
      type: notification_type(entry.type),
      title: entry.title,
      body: entry.body,
      is_read: entry.is_read,
      read_at: Map.get(entry, :read_at),
      metadata: entry.metadata,
      actor_id: Map.get(entry, :actor_id),
      inserted_at: entry.inserted_at
    }
  end

  defp notification_type(type) when is_atom(type), do: Atom.to_string(type)
  defp notification_type(type), do: type

  defp normalize_positive(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_positive(_value, default), do: default

  defp normalize_per_page(value) do
    value
    |> normalize_positive(@default_per_page)
    |> min(@max_per_page)
  end

  defp total_pages(0, _per_page), do: 0
  defp total_pages(total, per_page), do: div(total + per_page - 1, per_page)

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end

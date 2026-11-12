defmodule Marrylocal.NotificationsTest do
  use Marrylocal.DataCase, async: true

  import Ecto.Query
  import Marrylocal.AccountsFixtures

  alias Marrylocal.Notifications
  alias Marrylocal.Notifications.Notification
  alias Marrylocal.Repo

  defp notification_fixture(user, attrs \\ %{}) do
    {:ok, notification} =
      Notifications.insert_notification(
        Map.merge(
          %{
            user_id: user.id,
            type: :profile_like,
            title: "New profile like",
            body: "Someone liked your profile."
          },
          attrs
        )
      )

    notification
  end

  defp age_notification!(notification, attrs) do
    Repo.update_all(
      from(n in Notification, where: n.id == ^notification.id),
      set: Map.to_list(attrs)
    )
  end

  test "mark_read records the first read timestamp and keeps it on repeat" do
    user = user_fixture()
    notification = notification_fixture(user)

    assert is_nil(notification.read_at)

    assert {:ok, read} = Notifications.mark_read(user.id, notification.id)
    assert read.is_read
    assert %DateTime{} = read.read_at

    first_read_at = read.read_at

    assert {:ok, again} = Notifications.mark_read(user.id, notification.id)
    assert again.read_at == first_read_at
  end

  test "mark_all_read timestamps every newly read notification" do
    user = user_fixture()
    first = notification_fixture(user)
    second = notification_fixture(user, %{type: :mutual_match, title: "It's a match!"})

    assert Notifications.mark_all_read(user.id) == 2

    for notification <- [first, second] do
      reloaded = Repo.get!(Notification, notification.id)
      assert reloaded.is_read
      assert %DateTime{} = reloaded.read_at
    end
  end

  test "delete_expired_notifications applies the retention policy" do
    user = user_fixture()
    now = ~U[2026-11-11 12:00:00Z]
    seconds = fn days -> DateTime.add(now, -days * 86_400, :second) end

    old_unread = notification_fixture(user, %{title: "Old unread"})
    fresh_unread = notification_fixture(user, %{title: "Fresh unread"})
    old_read = notification_fixture(user, %{title: "Old read"})
    fresh_read = notification_fixture(user, %{title: "Fresh read"})
    legacy_read = notification_fixture(user, %{title: "Legacy read"})
    old_system = notification_fixture(user, %{type: :system, title: "Old system"})
    fresh_system = notification_fixture(user, %{type: :system, title: "Fresh system"})

    age_notification!(old_unread, %{
      inserted_at: seconds.(100),
      updated_at: seconds.(100),
      is_read: false,
      read_at: nil
    })

    age_notification!(fresh_unread, %{
      inserted_at: seconds.(10),
      updated_at: seconds.(10),
      is_read: false,
      read_at: nil
    })

    age_notification!(old_read, %{
      inserted_at: seconds.(40),
      updated_at: seconds.(31),
      is_read: true,
      read_at: seconds.(31)
    })

    age_notification!(fresh_read, %{
      inserted_at: seconds.(40),
      updated_at: seconds.(10),
      is_read: true,
      read_at: seconds.(10)
    })

    age_notification!(legacy_read, %{
      inserted_at: seconds.(40),
      updated_at: seconds.(31),
      is_read: true,
      read_at: nil
    })

    age_notification!(old_system, %{
      inserted_at: seconds.(400),
      updated_at: seconds.(400),
      is_read: true,
      read_at: seconds.(400)
    })

    age_notification!(fresh_system, %{
      inserted_at: seconds.(200),
      updated_at: seconds.(200),
      is_read: true,
      read_at: seconds.(200)
    })

    assert Notifications.delete_expired_notifications(now) == 4

    assert is_nil(Repo.get(Notification, old_unread.id))
    assert is_nil(Repo.get(Notification, old_read.id))
    assert is_nil(Repo.get(Notification, legacy_read.id))
    assert is_nil(Repo.get(Notification, old_system.id))

    refute is_nil(Repo.get(Notification, fresh_unread.id))
    refute is_nil(Repo.get(Notification, fresh_read.id))
    refute is_nil(Repo.get(Notification, fresh_system.id))
  end
end

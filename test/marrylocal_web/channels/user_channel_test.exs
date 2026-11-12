defmodule MarrylocalWeb.UserChannelTest do
  use MarrylocalWeb.ConnCase, async: false

  import Phoenix.ChannelTest
  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts
  alias MarrylocalWeb.Presence

  @endpoint MarrylocalWeb.Endpoint

  test "tracks an authenticated user in global presence on join" do
    user = Accounts.record_login(user_fixture())

    socket =
      socket(MarrylocalWeb.UserSocket, "user_socket:#{user.id}", %{
        current_user_id: user.id,
        current_user: user
      })

    {:ok, _reply, _channel} =
      subscribe_and_join(
        socket,
        MarrylocalWeb.UserChannel,
        "user_notifications:#{user.id}"
      )

    assert_push("presence_state", state)

    assert %{metas: [meta | _]} = state["user:#{user.id}"]
    assert meta.user_id == user.id
    assert is_binary(meta.last_login)
    assert Presence.online?(user.id)
    assert MapSet.member?(Presence.online_user_ids(), user.id)
  end
end

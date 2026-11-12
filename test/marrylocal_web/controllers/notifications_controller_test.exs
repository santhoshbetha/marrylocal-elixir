defmodule MarrylocalWeb.NotificationsControllerTest do
  use MarrylocalWeb.ConnCase, async: true

  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts
  alias Marrylocal.Notifications

  setup %{conn: conn} do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user)

    {:ok, like_notification} =
      Notifications.insert_notification(%{
        user_id: user.id,
        type: :profile_like,
        title: "New profile like",
        body: "Someone in your community liked your profile."
      })

    {:ok, _filtered_notification} =
      Notifications.insert_notification(%{
        user_id: user.id,
        type: :profile_shortlist,
        title: "Shortlist updated",
        body: "This type is not exposed by the inbox contract."
      })

    conn = put_req_header(conn, "authorization", "Bearer #{token}")

    %{conn: conn, user: user, notification: like_notification}
  end

  test "lists only the supported notification types with unread count", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/notifications")

    response = json_response(conn, 200)
    data = response["data"]

    assert [notification] = data["notifications"]
    assert notification["type"] == "profile_like"
    assert notification["title"] == "New profile like"
    assert data["unread_count"] == 1
    assert data["pagination"]["total"] == 1
  end

  test "marks one notification as read", %{conn: conn, notification: notification} do
    conn = patch(conn, ~p"/api/v1/notifications/#{notification.id}/read")

    response = json_response(conn, 200)
    assert response["data"]["notification"]["is_read"] == true
    assert response["data"]["notification"]["read_at"] != nil
    assert response["data"]["unread_count"] == 0
  end

  test "marks all notifications as read", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/notifications/mark-all-read")

    response = json_response(conn, 200)
    assert response["data"]["updated"] == 2
    assert response["data"]["unread_count"] == 0
  end
end

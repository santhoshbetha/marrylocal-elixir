defmodule MarrylocalWeb.PasswordChangeControllerTest do
  use MarrylocalWeb.ConnCase, async: true

  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts

  setup %{conn: conn} do
    user = user_fixture()

    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{
        password: "Password123!",
        password_confirmation: "Password123!"
      })

    token = Accounts.generate_user_session_token(user)
    conn = put_req_header(conn, "authorization", "Bearer #{token}")

    {:ok, conn: conn, user: user}
  end

  test "changes the password when the current password matches", %{conn: conn, user: user} do
    conn =
      put(conn, ~p"/api/v1/auth/password", %{
        "user" => %{
          "current_password" => "Password123!",
          "password" => "NewPassword456!",
          "password_confirmation" => "NewPassword456!"
        }
      })

    body = json_response(conn, 200)

    assert body["status"] == "success"
    assert is_binary(body["data"]["token"])
    assert Accounts.get_user_by_email_and_password(user.email, "Password123!") == nil
    assert Accounts.get_user_by_email_and_password(user.email, "NewPassword456!")
  end

  test "rejects an incorrect current password", %{conn: conn} do
    conn =
      put(conn, ~p"/api/v1/auth/password", %{
        "user" => %{
          "current_password" => "WrongPassword1!",
          "password" => "NewPassword456!",
          "password_confirmation" => "NewPassword456!"
        }
      })

    body = json_response(conn, 422)

    assert body["code"] == "invalid_current_password"
  end
end

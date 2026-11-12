defmodule MarrylocalWeb.ProfileRoleSerializationTest do
  use MarrylocalWeb.ConnCase, async: true

  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts
  alias Marrylocal.Repo

  test "login and profile fetch always include the admin role", %{conn: conn} do
    user = user_fixture() |> set_password()

    {:ok, admin} =
      user
      |> Ecto.Changeset.change(role: :admin)
      |> Repo.update()

    login_conn =
      post(conn, ~p"/api/v1/auth/login", %{
        "user" => %{"email" => admin.email, "password" => valid_user_password()}
      })

    login_body = json_response(login_conn, 200)
    assert login_body["data"]["user"]["role"] == "admin"

    token = login_body["data"]["token"]

    profile_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/api/v1/profiles/me")

    profile_body = json_response(profile_conn, 200)
    assert profile_body["data"]["profile"]["role"] == "admin"

    # The token itself remains valid and the role is still present on a second fetch.
    assert {session_user, _inserted_at} = Accounts.get_user_by_session_token(token)
    assert session_user.role == :admin
  end
end

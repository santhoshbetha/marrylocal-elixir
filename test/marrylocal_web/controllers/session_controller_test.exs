defmodule MarrylocalWeb.SessionControllerTest do
  use MarrylocalWeb.ConnCase, async: true

  import Marrylocal.AccountsFixtures

  describe "POST /api/v1/auth/login" do
    test "returns an opaque bearer token for valid credentials", %{conn: conn} do
      user = user_fixture() |> set_password()

      conn =
        post(conn, ~p"/api/v1/auth/login", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password()
          }
        })

      response = json_response(conn, 200)
      assert response["status"] == "success"
      assert is_binary(response["data"]["token"])
      assert response["data"]["user"]["id"] == user.id
      assert response["data"]["user"]["email_verified"] == true
    end

    test "rejects invalid credentials", %{conn: conn} do
      user = user_fixture() |> set_password()

      conn =
        post(conn, ~p"/api/v1/auth/login", %{
          "user" => %{"email" => user.email, "password" => "wrong-password"}
        })

      assert json_response(conn, 422)["status"] == "error"
    end
  end
end

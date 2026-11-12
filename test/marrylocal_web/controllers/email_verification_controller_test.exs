defmodule MarrylocalWeb.EmailVerificationControllerTest do
  use MarrylocalWeb.ConnCase, async: true

  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts

  describe "POST /api/v1/auth/verify-email" do
    test "confirms an account and returns a fresh bearer session", %{conn: conn} do
      user = unconfirmed_user_fixture()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_confirmation_instructions(user, url)
        end)

      conn = post(conn, ~p"/api/v1/auth/verify-email", %{"token" => token})
      response = json_response(conn, 200)

      assert response["status"] == "success"
      assert is_binary(response["data"]["token"])
      assert response["data"]["user"]["email"] == user.email
      assert response["data"]["user"]["email_verified"] == true

      confirmed = Accounts.get_user(user.id)
      assert confirmed.confirmed_at
      assert confirmed.email_verified
    end

    test "rejects an invalid confirmation token", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/auth/verify-email", %{"token" => "invalid-token"})

      assert json_response(conn, 422)["status"] == "error"
    end

    test "requires a token", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/auth/verify-email", %{})

      assert json_response(conn, 400)["status"] == "error"
    end
  end

  describe "POST /api/v1/auth/resend-confirmation" do
    test "accepts a resend without revealing whether the account exists", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/auth/resend-confirmation", %{
          "email" => "missing@example.com"
        })

      assert json_response(conn, 202)["status"] == "success"
    end
  end
end

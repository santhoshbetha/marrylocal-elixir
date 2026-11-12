defmodule MarrylocalWeb.ResetPasswordControllerTest do
  use MarrylocalWeb.ConnCase, async: true

  import Ecto.Query
  import Swoosh.TestAssertions
  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts
  alias Marrylocal.Accounts.UserToken
  alias Marrylocal.Repo

  defp insert_reset_token(user) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
    Repo.insert!(user_token)
    encoded_token
  end

  defp age_reset_tokens(user, amount, unit) do
    inserted_at = DateTime.add(DateTime.utc_now(:second), -amount, unit)

    Repo.update_all(
      from(t in UserToken,
        where: t.user_id == ^user.id and t.context == "reset_password"
      ),
      set: [inserted_at: inserted_at]
    )
  end

  test "forgot-password returns 200 for unknown emails", %{conn: conn} do
    conn =
      conn
      |> Map.put(:remote_ip, {10, 10, 0, 1})
      |> post(~p"/api/v1/auth/forgot-password", %{"email" => "missing@example.com"})

    body = json_response(conn, 200)
    assert body["message"] =~ "If an account exists"
    refute_email_sent()
  end

  test "forgot-password stores only the SHA-256 hash and emails a one-hour link", %{conn: conn} do
    user = unconfirmed_user_fixture()

    conn =
      conn
      |> Map.put(:remote_ip, {10, 10, 0, 2})
      |> post(~p"/api/v1/auth/forgot-password", %{"email" => String.upcase(user.email)})

    assert json_response(conn, 200)

    assert_email_sent(fn email ->
      assert email.to == [{user.first_name, user.email}]
      assert email.subject == "Reset your password"
      assert email.text_body =~ "This link expires in 1 hour."

      [_, raw_token] = Regex.run(~r/token=([A-Za-z0-9_-]+)/, email.text_body)
      {:ok, decoded_token} = Base.url_decode64(raw_token, padding: false)
      expected_hash = Base.encode64(:crypto.hash(:sha256, decoded_token), padding: false)

      stored = Repo.one!(from t in UserToken, where: t.context == "reset_password")
      assert stored.token == expected_hash
      assert stored.sent_to == user.email

      true
    end)
  end

  test "POST /api/v1/auth/reset-password updates the password and revokes every token",
       %{conn: conn} do
    user = unconfirmed_user_fixture()

    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{
        "password" => "OldPassword123!",
        "password_confirmation" => "OldPassword123!"
      })

    session_token = Accounts.generate_user_session_token(user)
    reset_token = insert_reset_token(user)

    conn =
      post(conn, ~p"/api/v1/auth/reset-password", %{
        "token" => reset_token,
        "user" => %{
          "password" => "NewPassword456!",
          "password_confirmation" => "NewPassword456!"
        }
      })

    assert json_response(conn, 200)

    assert Accounts.get_user_by_email_and_password(user.email, "NewPassword456!")
    assert Accounts.get_user_by_email_and_password(user.email, "OldPassword123!") == nil
    assert Accounts.get_user_by_session_token(session_token) == nil
    assert Repo.all(UserToken.by_user_and_contexts_query(user, :all)) == []

    # The reset token is consumed by the transaction and cannot be replayed.
    replay =
      post(conn, ~p"/api/v1/auth/reset-password", %{
        "token" => reset_token,
        "user" => %{
          "password" => "AnotherPassword789!",
          "password_confirmation" => "AnotherPassword789!"
        }
      })

    assert json_response(replay, 401)
  end

  test "PUT /api/v1/auth/reset-password/:token stays compatible with the React client",
       %{conn: conn} do
    user = unconfirmed_user_fixture()
    reset_token = insert_reset_token(user)

    conn =
      put(conn, ~p"/api/v1/auth/reset-password/#{reset_token}", %{
        "user" => %{
          "password" => "NewPassword456!",
          "password_confirmation" => "NewPassword456!"
        }
      })

    assert json_response(conn, 200)
    assert Accounts.get_user_by_email_and_password(user.email, "NewPassword456!")
  end

  test "rejects a reset token after the strict one-hour window", %{conn: conn} do
    user = unconfirmed_user_fixture()
    reset_token = insert_reset_token(user)
    age_reset_tokens(user, 61, :minute)

    conn =
      post(conn, ~p"/api/v1/auth/reset-password", %{
        "token" => reset_token,
        "user" => %{
          "password" => "NewPassword456!",
          "password_confirmation" => "NewPassword456!"
        }
      })

    assert json_response(conn, 401)
  end

  test "rate limits repeated requests without revealing account existence", %{conn: conn} do
    conn = Map.put(conn, :remote_ip, {10, 10, 0, 3})
    email = "rate-limit-#{System.unique_integer([:positive])}@example.com"

    assert %{"message" => _} =
             conn
             |> post(~p"/api/v1/auth/forgot-password", %{"email" => email})
             |> json_response(200)

    assert %{"message" => _} =
             conn
             |> post(~p"/api/v1/auth/forgot-password", %{"email" => email})
             |> json_response(200)

    assert %{"error" => "too_many_requests"} =
             conn
             |> post(~p"/api/v1/auth/forgot-password", %{"email" => email})
             |> json_response(429)
  end

  test "honeypot submissions look successful without sending mail", %{conn: conn} do
    conn =
      conn
      |> Map.put(:remote_ip, {10, 10, 0, 4})
      |> post(~p"/api/v1/auth/forgot-password", %{
        "email" => "bot@example.com",
        "nickname" => "spam"
      })

    assert json_response(conn, 200)
    refute_email_sent()
  end
end

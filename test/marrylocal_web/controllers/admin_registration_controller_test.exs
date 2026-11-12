defmodule MarrylocalWeb.AdminRegistrationControllerTest do
  use MarrylocalWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  alias Marrylocal.Accounts

  @invite_code "TEST_ADMIN_INVITE_123"

  setup do
    previous = System.get_env("ADMIN_INVITE_CODE")
    System.put_env("ADMIN_INVITE_CODE", @invite_code)

    on_exit(fn ->
      if previous do
        System.put_env("ADMIN_INVITE_CODE", previous)
      else
        System.delete_env("ADMIN_INVITE_CODE")
      end
    end)

    :ok
  end

  defp valid_admin_attrs(overrides \\ %{}) do
    suffix = System.unique_integer([:positive])
    phone_suffix = Integer.to_string(rem(suffix, 1_000_000_000)) |> String.pad_leading(9, "0")

    Enum.into(overrides, %{
      "first_name" => "Admin",
      "last_name" => "Tester",
      "birth_date" => "1990-01-01",
      "gender" => "Female",
      "email" => "admin#{suffix}@example.com",
      "phone_number" => "9#{phone_suffix}",
      "password" => "Password123!",
      "invite_code" => @invite_code
    })
  end

  test "registers an admin, persists only age, and sends the confirmation email", %{conn: conn} do
    attrs = valid_admin_attrs()

    conn = post(conn, ~p"/api/v1/auth/admin-register", attrs)
    body = json_response(conn, 201)

    assert body["status"] == "success"
    assert body["data"]["user"]["role"] == "admin"
    assert body["data"]["user"]["email"] == attrs["email"]

    user = Accounts.get_user_by_email(attrs["email"])
    assert user.role == :admin
    assert user.user_state == :active
    assert user.age >= 18
    assert is_nil(user.date_of_birth)
    refute user.email_verified

    assert_email_sent(fn email ->
      assert email.subject == "Confirmation instructions"
      assert email.text_body =~ "/verify-email?token="
      true
    end)
  end

  test "accepts the nested admin payload shape", %{conn: conn} do
    attrs = valid_admin_attrs()

    conn = post(conn, ~p"/api/v1/auth/admin-register", %{"admin" => attrs})
    assert json_response(conn, 201)["status"] == "success"
    assert Accounts.get_user_by_email(attrs["email"]).role == :admin
  end

  test "rejects an invalid invite code with 403 before creating an account", %{conn: conn} do
    attrs = valid_admin_attrs(%{"invite_code" => "WRONG_CODE_123"})

    conn = post(conn, ~p"/api/v1/auth/admin-register", attrs)
    body = json_response(conn, 403)

    assert body["code"] == "invalid_invite_code"
    assert body["message"] =~ "invalid"
    refute Accounts.get_user_by_email(attrs["email"])
    refute_email_sent()
  end

  test "rejects malformed fields and underage registrations with 422", %{conn: conn} do
    attrs =
      valid_admin_attrs(%{
        "phone_number" => "12345",
        "password" => "short",
        "birth_date" => "2015-01-01"
      })

    conn = post(conn, ~p"/api/v1/auth/admin-register", attrs)
    body = json_response(conn, 422)

    assert body["status"] == "error"
    assert body["errors"]["phone_number"]
    assert body["errors"]["password"]
    assert body["errors"]["date_of_birth"]
    refute Accounts.get_user_by_email(attrs["email"])
  end

  test "rejects every code when ADMIN_INVITE_CODE is not configured", %{conn: conn} do
    System.delete_env("ADMIN_INVITE_CODE")
    attrs = valid_admin_attrs()

    conn = post(conn, ~p"/api/v1/auth/admin-register", attrs)

    assert json_response(conn, 403)["code"] == "invalid_invite_code"
    refute Accounts.get_user_by_email(attrs["email"])
  end
end

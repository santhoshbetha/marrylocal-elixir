defmodule MarrylocalWeb.HandleAvailabilityControllerTest do
  use MarrylocalWeb.ConnCase, async: true

  import Marrylocal.AccountsFixtures

  test "reports a free handle as available", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/auth/check-handle", handle: "fresh_handle")

    body = json_response(conn, 200)

    assert body["available"] == true
    assert body["message"] == "Handle is available!"
  end

  test "reports a taken handle case-insensitively after stripping @", %{conn: conn} do
    user = user_fixture()

    conn =
      get(conn, ~p"/api/v1/auth/check-handle", handle: "@#{String.upcase(user.user_handle)}")

    body = json_response(conn, 200)

    assert body["available"] == false
    assert body["message"] == "This handle is already taken."
  end

  test "explains invalid handle formats", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/auth/check-handle", handle: "1bad")

    body = json_response(conn, 200)

    assert body["available"] == false
    assert body["message"] =~ "5-15 characters"
  end

  test "requires a handle parameter", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/auth/check-handle")

    body = json_response(conn, 422)

    assert body["available"] == false
    assert body["message"] =~ "Enter a handle"
  end
end

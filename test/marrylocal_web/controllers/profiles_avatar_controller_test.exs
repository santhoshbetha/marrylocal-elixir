defmodule MarrylocalWeb.ProfilesAvatarControllerTest do
  use MarrylocalWeb.ConnCase, async: true

  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts

  setup %{conn: conn} do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("origin", "http://localhost:5173")

    {:ok, conn: conn, user: user}
  end

  test "rejects a request without a file with a descriptive JSON error", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/profiles/me/avatar", %{})

    body = json_response(conn, 422)

    assert body["status"] == "error"
    assert body["code"] == "missing_avatar"
    assert body["message"] =~ "avatar"
    assert get_resp_header(conn, "access-control-allow-origin") == ["http://localhost:5173"]
  end

  test "logs full telemetry when Waffle rejects the upload before storage", %{conn: conn} do
    missing_path =
      Path.join(
        System.tmp_dir!(),
        "missing-avatar-#{System.unique_integer([:positive])}.png"
      )

    upload = %Plug.Upload{
      path: missing_path,
      filename: "missing-avatar.png",
      content_type: "image/png"
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        conn = post(conn, ~p"/api/v1/profiles/me/avatar", %{"avatar" => upload})

        body = json_response(conn, 422)

        assert body["status"] == "error"
        assert body["code"] == "invalid_avatar"
      end)

    assert log =~ "❌ CLOUDFLARE R2 UPLOAD FAILURE CHANGESET"
    assert log =~ "user_id="
    assert log =~ "request_id="
    assert log =~ "bucket="
    assert log =~ "endpoint="
    assert log =~ "credentials_configured="
  end
end

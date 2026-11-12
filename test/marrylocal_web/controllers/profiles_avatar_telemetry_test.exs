defmodule MarrylocalWeb.ProfilesAvatarTelemetryTest do
  use MarrylocalWeb.ConnCase, async: false

  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts
  alias Marrylocal.TestSupport.RaisingAvatarStorage

  setup %{conn: conn} do
    previous_storage = Application.get_env(:waffle, :storage)
    Application.put_env(:waffle, :storage, RaisingAvatarStorage)

    on_exit(fn ->
      Application.put_env(:waffle, :storage, previous_storage)
      Application.delete_env(:marrylocal, :test_storage_status)
    end)

    user = user_fixture()
    token = Accounts.generate_user_session_token(user)

    conn = put_req_header(conn, "authorization", "Bearer #{token}")

    upload_path =
      Path.join(
        System.tmp_dir!(),
        "raising-avatar-#{System.unique_integer([:positive])}.png"
      )

    File.write!(upload_path, <<137, 80, 78, 71, 13, 10, 26, 10>>)
    on_exit(fn -> File.rm(upload_path) end)

    {:ok, conn: conn, user: user, upload_path: upload_path}
  end

  test "rescue path logs the explicit R2 marker and a 403 classification", %{
    conn: conn,
    upload_path: path
  } do
    log = capture_upload_log(conn, path)

    assert log =~ "❌ CLOUDFLARE R2 UPLOAD FAILURE EXCEPTION:"
    assert log =~ "simulated R2 bucket access denied (status 403)"
    assert log =~ "CLOUDFLARE R2 UPLOAD DIAGNOSTICS"
    assert log =~ "status=403"
    assert log =~ "status_hint=credentials_forbidden_or_bucket_policy"
    assert log =~ "bucket="
    assert log =~ "endpoint="
    assert log =~ "credentials_configured="
  end

  test "404 failures are classified as endpoint or bucket routing problems", %{
    conn: conn,
    upload_path: path
  } do
    Application.put_env(:marrylocal, :test_storage_status, 404)

    log = capture_upload_log(conn, path)

    assert log =~ "❌ CLOUDFLARE R2 UPLOAD FAILURE EXCEPTION:"
    assert log =~ "status=404"
    assert log =~ "status_hint=endpoint_or_bucket_not_found"
  end

  defp capture_upload_log(conn, path) do
    upload = %Plug.Upload{
      path: path,
      filename: "raising-avatar.png",
      content_type: "image/png"
    }

    ExUnit.CaptureLog.capture_log(fn ->
      conn = post(conn, ~p"/api/v1/profiles/me/avatar", %{"avatar" => upload})
      body = json_response(conn, 502)

      assert body["status"] == "error"
      assert body["code"] == "avatar_storage_unavailable"
      assert body["details"] =~ "simulated R2 bucket access denied"
    end)
  end
end

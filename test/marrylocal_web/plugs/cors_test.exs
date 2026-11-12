defmodule MarrylocalWeb.Plugs.CORSTest do
  use MarrylocalWeb.ConnCase, async: true

  test "OPTIONS preflight from the React dev server is accepted", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "http://127.0.0.1:5173")
      |> put_req_header("access-control-request-method", "POST")
      |> put_req_header("access-control-request-headers", "authorization, content-type")
      |> options("/api/v1/profiles/me/avatar")

    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-origin") == ["http://127.0.0.1:5173"]

    assert get_resp_header(conn, "access-control-allow-headers") == [
             "authorization, content-type"
           ]

    [methods] = get_resp_header(conn, "access-control-allow-methods")
    assert methods =~ "POST"
    assert methods =~ "OPTIONS"
  end

  test "authentication failures still carry CORS headers", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "http://localhost:5173")
      |> get("/api/v1/profiles/me")

    assert conn.status == 401
    assert get_resp_header(conn, "access-control-allow-origin") == ["http://localhost:5173"]
  end

  test "requests from unlisted origins do not receive CORS headers", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "https://evil.example")
      |> get("/api/v1/profiles/me")

    assert get_resp_header(conn, "access-control-allow-origin") == []
  end
end

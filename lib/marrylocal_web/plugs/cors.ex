defmodule MarrylocalWeb.Plugs.CORS do
  @moduledoc """
  CORS support for the local React client and configured production origins.

  Authentication uses the `Authorization` header rather than cookies, so the
  allowed origin is echoed back instead of using a wildcard. Override the list
  in production with a comma-separated `CORS_ALLOWED_ORIGINS` environment
  variable.

  This plug is mounted at the top of `MarrylocalWeb.Endpoint`, before
  `Plug.Parsers`, so preflights and early error responses (for example a
  multipart parser failure or a storage outage) still carry the headers the
  browser needs in order to surface the real status code.
  """

  import Plug.Conn

  @default_origins [
    "http://localhost:5173",
    "http://127.0.0.1:5173",
    "http://localhost:5174",
    "http://127.0.0.1:5174",
    "http://localhost:3000",
    "http://127.0.0.1:3000"
  ]

  @allowed_headers "Authorization, Content-Type, Accept, X-Requested-With"
  @allowed_methods "GET, POST, PUT, PATCH, DELETE, OPTIONS"
  @max_age "86400"

  def init(opts), do: opts

  def call(conn, _opts) do
    origin = conn |> get_req_header("origin") |> List.first()

    conn =
      if origin in allowed_origins() do
        requested_headers =
          conn
          |> get_req_header("access-control-request-headers")
          |> List.first()

        conn
        |> put_resp_header("access-control-allow-origin", origin)
        |> put_resp_header("access-control-allow-methods", @allowed_methods)
        |> put_resp_header("access-control-allow-headers", requested_headers || @allowed_headers)
        |> put_resp_header("access-control-max-age", @max_age)
        |> put_resp_header("access-control-expose-headers", "Content-Type, X-Request-Id")
        |> append_vary_origin()
      else
        conn
      end

    if conn.method == "OPTIONS" do
      conn
      |> send_resp(204, "")
      |> halt()
    else
      conn
    end
  end

  defp append_vary_origin(conn) do
    existing =
      conn
      |> get_resp_header("vary")
      |> Enum.join(", ")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    vary =
      if "Origin" in existing do
        Enum.join(existing, ", ")
      else
        Enum.join(existing ++ ["Origin"], ", ")
      end

    put_resp_header(conn, "vary", vary)
  end

  defp allowed_origins do
    case System.get_env("CORS_ALLOWED_ORIGINS") do
      nil ->
        @default_origins

      value ->
        value
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end
end

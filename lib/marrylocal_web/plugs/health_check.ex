defmodule MarrylocalWeb.Plugs.HealthCheck do
  @moduledoc """
  Proactive container health check for Kamal and other orchestrators.

  This plug is mounted in the endpoint before `Plug.Parsers` and the router so
  `/health` answers immediately without session, host, SSL, or API middleware.

  Two checks run on every request:

    * PostgreSQL answers a lightweight `SELECT 1`.
    * Ecto reports no pending (`:down`) migrations for `Marrylocal.Repo`.

  Returning `503` while a migration is pending prevents a new container from
  receiving live traffic before its schema is ready. The release server script
  also runs migrations at boot, so this is a second, defensive gate.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  @health_paths ["/health", "/health/"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: path} = conn, _opts) when path in @health_paths do
    failures =
      [database_failure(), migrations_failure()]
      |> Enum.reject(&is_nil/1)

    case failures do
      [] ->
        respond(conn, 200, %{status: "healthy"})

      failures ->
        respond(conn, 503, %{status: "unhealthy", failures: failures})
    end
  end

  def call(conn, _opts), do: conn

  defp database_failure do
    case Ecto.Adapters.SQL.query(Marrylocal.Repo, "SELECT 1", [], timeout: 2_000) do
      {:ok, %{rows: [[1]]}} ->
        nil

      {:ok, _result} ->
        Logger.error("Health check SELECT 1 returned an unexpected result")
        failure("database", "PostgreSQL returned an unexpected result for SELECT 1")

      {:error, reason} ->
        Logger.error("Health check database query failed: #{inspect(reason)}")
        failure("database", "PostgreSQL did not answer SELECT 1")
    end
  rescue
    error ->
      Logger.error("Health check database query raised: #{Exception.message(error)}")
      failure("database", "PostgreSQL is not reachable")
  catch
    kind, reason ->
      Logger.error("Health check database query failed: #{inspect({kind, reason})}")
      failure("database", "PostgreSQL is not reachable")
  end

  defp migrations_failure do
    pending_versions =
      Marrylocal.Repo
      |> Ecto.Migrator.migrations()
      |> Enum.filter(fn {direction, _version, _name} -> direction == :down end)
      |> Enum.map(fn {_direction, version, _name} -> version end)

    case pending_versions do
      [] ->
        nil

      versions ->
        Logger.warning("Health check found pending migrations: #{inspect(versions)}")

        failure("migrations", "Pending database migrations must be applied")
        |> Map.put(:pending_versions, versions)
    end
  rescue
    error ->
      Logger.error("Health check migration lookup raised: #{Exception.message(error)}")
      failure("migrations", "Could not determine migration status")
  catch
    kind, reason ->
      Logger.error("Health check migration lookup failed: #{inspect({kind, reason})}")
      failure("migrations", "Could not determine migration status")
  end

  defp failure(check, message), do: %{check: check, message: message}

  defp respond(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(payload))
    |> halt()
  end
end

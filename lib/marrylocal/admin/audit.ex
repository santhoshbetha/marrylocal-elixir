defmodule Marrylocal.Admin.Audit do
  @moduledoc """
  Writes structured admin write-action audit records.

  `X-Admin-Client: mcp` marks actions originating from the local MCP server;
  everything else is recorded as `web_ui`.
  """

  require Logger

  alias Marrylocal.Admin.AuditLog
  alias Marrylocal.Repo

  def record(conn, action, target_id \\ nil, metadata \\ %{}) do
    source =
      cond do
        conn.assigns[:mcp_authenticated] == true -> "mcp"
        client_header(conn) == "mcp" -> "mcp"
        true -> "web_ui"
      end

    admin = conn.assigns[:current_user]

    attrs = %{
      admin_id: admin && admin.id,
      source: source,
      action: to_string(action),
      target_id: target_id && to_string(target_id),
      metadata: stringify(metadata)
    }

    case %AuditLog{} |> AuditLog.changeset(attrs) |> Repo.insert() do
      {:ok, _log} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Could not write admin audit log: #{inspect(changeset.errors)}")
        :ok
    end
  end

  defp client_header(conn) do
    conn
    |> Plug.Conn.get_req_header("x-admin-client")
    |> List.first()
    |> case do
      value when is_binary(value) -> value |> String.trim() |> String.downcase()
      _ -> nil
    end
  end

  defp stringify(%{} = metadata) do
    Map.new(metadata, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp stringify(values) when is_list(values), do: Enum.map(values, &stringify/1)
  defp stringify(value) when is_boolean(value), do: value
  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end

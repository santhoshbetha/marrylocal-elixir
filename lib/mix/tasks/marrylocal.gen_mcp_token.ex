defmodule Mix.Tasks.Marrylocal.GenMcpToken do
  @shortdoc "Generates the long-lived scoped admin token used by the MarryLocal MCP server"

  @moduledoc """
  Generates a high-entropy bearer token for the local MarryLocal admin MCP
  server and prints the environment values it needs.

      mix marrylocal.gen_mcp_token admin@marrylocal.test

  The token is **not** stored in the database. It is compared against the
  `MCP_ADMIN_TOKEN` environment variable on every admin API request and is only
  accepted for `/api/v1/admin/*` paths. Keep it in a secret manager and rotate it
  by generating a new value and restarting the backend.

  The email argument is optional. When supplied, the task verifies that the
  account exists and has the `admin` role, so typos are caught before the MCP
  client is configured.
  """

  use Mix.Task

  alias Marrylocal.Accounts

  @impl Mix.Task
  def run(args) do
    {opts, argv, _invalid} = OptionParser.parse(args, strict: [length: :integer])
    email = List.first(argv) || System.get_env("MCP_ADMIN_EMAIL")
    bytes = Keyword.get(opts, :length, 32)

    if bytes < 32 do
      Mix.raise("Token length must be at least 32 bytes.")
    end

    Mix.Task.run("app.start")

    verify_admin!(email)

    token =
      bytes
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    Mix.shell().info("""

    MarryLocal scoped admin MCP token generated.

    Add these values to the backend environment (and restart Phoenix):

      MCP_ADMIN_TOKEN=#{token}
      MCP_ADMIN_EMAIL=#{email || "admin@marrylocal.test"}

    Add these values to marrylocal-mcp/.env:

      MARRYLOCAL_API_URL=http://localhost:4000
      MARRYLOCAL_ADMIN_TOKEN=#{token}

    Store the token in your secret manager. It is shown only once and is never
    persisted by this task.
    """)

    case email do
      nil ->
        Mix.shell().info(
          "No admin email was supplied, so no account was verified. " <>
            "Set MCP_ADMIN_EMAIL to the admin account the token should act as."
        )

      _email ->
        :ok
    end
  end

  defp verify_admin!(nil), do: :ok

  defp verify_admin!(email) do
    alias Marrylocal.Accounts

    case Accounts.get_user_by_email(email) do
      %{role: role} when role in [:admin, "admin"] ->
        :ok

      %{role: role} ->
        Mix.raise(
          "#{email} exists but has role #{inspect(role)}. " <>
            "The MCP token may only resolve to an admin account."
        )

      nil ->
        Mix.raise(
          "No account exists for #{email}. Create or promote an admin first, " <>
            "or pass the correct email address."
        )
    end
  end
end

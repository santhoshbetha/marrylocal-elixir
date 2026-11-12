defmodule Marrylocal.Repo.Migrations.HashSessionTokens do
  use Ecto.Migration

  @doc """
  Moves `users_tokens.token` from raw `bytea` to the Base64-encoded SHA-256
  digest stored by `Marrylocal.Accounts.UserToken`.

  Existing rows hold raw bearer values, which cannot be safely reinterpreted as
  hashes. They are revoked once during deploy; every client receives a new
  token on next login.
  """

  def up do
    execute "DELETE FROM users_tokens"

    alter table(:users_tokens) do
      modify :token, :text, from: :binary
    end
  end

  def down do
    execute "DELETE FROM users_tokens"

    alter table(:users_tokens) do
      modify :token, :binary, from: :text
    end
  end
end

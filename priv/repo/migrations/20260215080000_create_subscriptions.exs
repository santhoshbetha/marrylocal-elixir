defmodule Marrylocal.Repo.Migrations.CreateSubscriptions do
  use Ecto.Migration

  def change do
    create table(:subscriptions) do
      # Reference to your User schema
      add :user_id, references(:users, on_delete: :delete_all), null: false

      # JSONB field for flexible data storage
      add :info, :map, default: %{}

      # Useful tracking fields
      # active, expired, canceled
      add :status, :string, default: "pending"
      add :valid_until, :utc_datetime

      timestamps()
    end

    # Index for fast lookups by user
    create index(:subscriptions, [:user_id])
    # GIN index for high-performance JSON searching if needed later
    create index(:subscriptions, [:info], using: :gin)
  end
end

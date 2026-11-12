defmodule Marrylocal.Repo.Migrations.AddReadAtToNotifications do
  use Ecto.Migration

  def change do
    alter table(:notifications) do
      add :read_at, :utc_datetime
    end

    create index(:notifications, [:user_id, :is_read, :inserted_at])
  end
end

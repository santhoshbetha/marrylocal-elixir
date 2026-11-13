defmodule Marrylocal.Repo.Migrations.CreateAdminAuditLogs do
  use Ecto.Migration

  def change do
    create table(:admin_audit_logs) do
      add :admin_id, references(:users, on_delete: :nilify_all)
      add :source, :string, null: false, default: "web_ui"
      add :action, :string, null: false
      add :target_id, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:admin_audit_logs, [:admin_id])
    create index(:admin_audit_logs, [:action])
    create index(:admin_audit_logs, [:inserted_at])
  end
end

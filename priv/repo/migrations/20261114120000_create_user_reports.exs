defmodule Marrylocal.Repo.Migrations.CreateUserReports do
  use Ecto.Migration

  def change do
    create table(:user_reports) do
      add :reporter_id, references(:users, on_delete: :delete_all), null: false
      add :reported_user_id, references(:users, on_delete: :delete_all), null: false
      add :reason, :string, null: false
      add :details, :text
      add :status, :string, null: false, default: "pending"
      add :reviewed_by_admin_id, references(:users, on_delete: :nilify_all)
      add :admin_notes, :text
      add :reviewed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:user_reports, [:status])
    create index(:user_reports, [:reported_user_id])
    create index(:user_reports, [:reporter_id])
    create index(:user_reports, [:inserted_at])

    create unique_index(:user_reports, [:reporter_id, :reported_user_id],
             where: "status = 'pending'",
             name: :user_reports_pending_unique_index
           )

    create constraint(:user_reports, :user_reports_no_self,
             check: "reporter_id <> reported_user_id"
           )

    create constraint(:user_reports, :user_reports_reason_allowed,
             check:
               "reason IN ('fake_profile', 'inappropriate_photos', 'harassment', 'married_or_taken', 'scam_or_spam', 'other')"
           )

    create constraint(:user_reports, :user_reports_status_allowed,
             check: "status IN ('pending', 'reviewed_action_taken', 'dismissed')"
           )
  end
end

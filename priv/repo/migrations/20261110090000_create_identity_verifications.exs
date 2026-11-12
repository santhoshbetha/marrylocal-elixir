defmodule Marrylocal.Repo.Migrations.CreateIdentityVerifications do
  use Ecto.Migration

  def change do
    create table(:identity_verifications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :document_type, :string, null: false
      add :document_number, :string, null: false
      add :document_image, :string, null: false
      add :status, :string, null: false, default: "pending_admin_review"
      add :rejection_reason, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:identity_verifications, [:user_id])

    create constraint(:identity_verifications, :identity_verifications_document_type_check,
             check: "document_type IN ('aadhaar', 'passport', 'license')"
           )

    create constraint(:identity_verifications, :identity_verifications_status_check,
             check:
               "status IN ('pending_bot_ocr', 'pending_admin_review', 'verified', 'rejected')"
           )
  end
end

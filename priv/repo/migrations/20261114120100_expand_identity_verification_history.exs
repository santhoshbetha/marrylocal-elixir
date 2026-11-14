defmodule Marrylocal.Repo.Migrations.ExpandIdentityVerificationHistory do
  use Ecto.Migration

  def up do
    # Every submission becomes its own permanent row. The old unique user index
    # made resubmission after a rejection impossible.
    drop index(:identity_verifications, [:user_id], name: :identity_verifications_user_id_index)

    create index(:identity_verifications, [:user_id])
    create index(:identity_verifications, [:status])

    alter table(:identity_verifications) do
      add :submitted_at, :utc_datetime
      add :reviewed_by_admin_id, references(:users, on_delete: :nilify_all)
      add :reviewed_at, :utc_datetime
      add :reviewer_notes, :text
    end

    create index(:identity_verifications, [:submitted_at])

    flush()

    execute("UPDATE identity_verifications SET submitted_at = COALESCE(inserted_at, NOW())")

    execute("""
    UPDATE identity_verifications
    SET reviewed_at = COALESCE(updated_at, NOW())
    WHERE status IN ('verified', 'rejected')
    """)

    # A document hash may only be actively claimed once. Rejected/expired
    # history rows keep their hash without blocking the owner's resubmission.
    drop index(:identity_verifications, [:identity_hash],
           name: :identity_verifications_identity_hash_index
         )

    create unique_index(:identity_verifications, [:identity_hash],
             where:
               "identity_hash IS NOT NULL AND status IN ('pending_bot_ocr', 'pending_admin_review', 'verified')",
             name: :identity_verifications_active_identity_hash_index
           )
  end

  def down do
    drop index(:identity_verifications, [:identity_hash],
           name: :identity_verifications_active_identity_hash_index
         )

    create unique_index(:identity_verifications, [:identity_hash],
             where: "identity_hash IS NOT NULL",
             name: :identity_verifications_identity_hash_index
           )

    drop index(:identity_verifications, [:submitted_at])

    alter table(:identity_verifications) do
      remove :reviewer_notes
      remove :reviewed_at
      remove :reviewed_by_admin_id
      remove :submitted_at
    end

    drop index(:identity_verifications, [:status])
    drop index(:identity_verifications, [:user_id], name: :identity_verifications_user_id_index)
    create unique_index(:identity_verifications, [:user_id])
  end
end

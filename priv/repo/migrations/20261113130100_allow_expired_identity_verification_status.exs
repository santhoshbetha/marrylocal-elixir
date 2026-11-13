defmodule Marrylocal.Repo.Migrations.AllowExpiredIdentityVerificationStatus do
  use Ecto.Migration

  def up do
    drop constraint(:identity_verifications, :identity_verifications_status_check)

    create constraint(:identity_verifications, :identity_verifications_status_check,
             check:
               "status IN ('pending_bot_ocr', 'pending_admin_review', 'verified', 'rejected', 'expired')"
           )
  end

  def down do
    drop constraint(:identity_verifications, :identity_verifications_status_check)

    create constraint(:identity_verifications, :identity_verifications_status_check,
             check:
               "status IN ('pending_bot_ocr', 'pending_admin_review', 'verified', 'rejected')"
           )
  end
end

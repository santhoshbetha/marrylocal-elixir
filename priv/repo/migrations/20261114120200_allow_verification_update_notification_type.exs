defmodule Marrylocal.Repo.Migrations.AllowVerificationUpdateNotificationType do
  use Ecto.Migration

  def up do
    drop constraint(:notifications, :notifications_type_check)

    create constraint(:notifications, :notifications_type_check,
             check:
               "type IN ('profile_like', 'mutual_match', 'profile_shortlist', 'system', 'admin_broadcast', 'verification_update')"
           )
  end

  def down do
    drop constraint(:notifications, :notifications_type_check)

    create constraint(:notifications, :notifications_type_check,
             check:
               "type IN ('profile_like', 'mutual_match', 'profile_shortlist', 'system', 'admin_broadcast')"
           )
  end
end

defmodule Marrylocal.Repo.Migrations.AddVerificationTiersAndSeedRecruitment do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :verified_at, :utc_datetime
      add :is_peer_verifier, :boolean, default: false, null: false
      add :is_available_to_vouch, :boolean, default: true, null: false
      add :seed_verifier_status, :string, default: "none", null: false
    end

    create constraint(:users, :users_seed_verifier_status_allowed,
             check:
               "seed_verifier_status IN ('none', 'invited', 'opted_in', 'opted_out', 'approved')"
           )

    create index(:users, [:city, :seed_verifier_status])
    create index(:users, [:seed_verifier_status])
    create index(:users, [:verified_at])

    # Existing peer-verified members with three vouches already qualify as
    # verifiers. Stamp verified_at for every already-verified account so the
    # expiry worker has a starting point.
    execute("""
    UPDATE users
    SET is_peer_verifier = true,
        vouch_credits_remaining = GREATEST(COALESCE(vouch_credits_remaining, 0), 5)
    WHERE peer_verified = true AND COALESCE(peer_vouches_received, 0) >= 3
    """)

    execute("""
    UPDATE users
    SET verified_at = COALESCE(updated_at, NOW())
    WHERE verified_at IS NULL
      AND (peer_verified = true OR aadhar_verified = true OR passport_verified = true OR license_verified = true)
    """)
  end

  def down do
    drop index(:users, [:verified_at])
    drop index(:users, [:seed_verifier_status])
    drop index(:users, [:city, :seed_verifier_status])
    drop constraint(:users, :users_seed_verifier_status_allowed)

    alter table(:users) do
      remove :seed_verifier_status
      remove :is_available_to_vouch
      remove :is_peer_verifier
      remove :verified_at
    end
  end
end

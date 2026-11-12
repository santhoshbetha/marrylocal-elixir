defmodule Marrylocal.Repo.Migrations.AddReferralLedgerToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :referred_by_id, references(:users, on_delete: :nilify_all)
      add :referral_credits_count, :integer, null: false, default: 0
    end

    execute """
    UPDATE users
    SET referral_code = 'ML' || upper(substr(md5(id::text), 1, 6))
    WHERE referral_code IS NULL
    """

    alter table(:users) do
      modify :referral_code, :string, null: false
    end

    create index(:users, [:referred_by_id])
  end

  def down do
    drop index(:users, [:referred_by_id])

    alter table(:users) do
      modify :referral_code, :string, null: true
      remove :referral_credits_count
      remove :referred_by_id
    end
  end
end

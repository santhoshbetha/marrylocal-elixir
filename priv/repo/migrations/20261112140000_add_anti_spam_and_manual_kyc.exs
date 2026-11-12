defmodule Marrylocal.Repo.Migrations.AddAntiSpamAndManualKyc do
  use Ecto.Migration

  def up do
    alter table(:identity_verifications) do
      add :identity_hash, :string
    end

    create unique_index(:identity_verifications, [:identity_hash],
             where: "identity_hash IS NOT NULL",
             name: :identity_verifications_identity_hash_index
           )

    create table(:user_photo_hashes) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :photo_hash, :string, null: false
      add :slot_index, :integer
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_photo_hashes, [:photo_hash],
             where: "active = true",
             name: :user_photo_hashes_active_photo_hash_index
           )

    create unique_index(:user_photo_hashes, [:user_id, :slot_index],
             name: :user_photo_hashes_user_slot_index
           )

    # Normalize legacy +91 / spaced values to the canonical ten-digit form.
    execute """
    UPDATE users
    SET phone_number = right(regexp_replace(phone_number, '\\D', '', 'g'), 10)
    WHERE phone_number IS NOT NULL
    """

    execute "CREATE UNIQUE INDEX IF NOT EXISTS users_phone_number_index ON users (phone_number)"
  end

  def down do
    execute "DROP INDEX IF EXISTS users_phone_number_index"
    drop table(:user_photo_hashes)

    drop index(:identity_verifications, [:identity_hash],
           name: :identity_verifications_identity_hash_index
         )

    alter table(:identity_verifications) do
      remove :identity_hash
    end
  end
end

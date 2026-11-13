defmodule Marrylocal.Repo.Migrations.CreatePeerVouches do
  use Ecto.Migration

  def change do
    create table(:peer_vouches) do
      add :voucher_id, references(:users, on_delete: :delete_all), null: false
      add :vouchee_id, references(:users, on_delete: :delete_all), null: false
      add :city, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:peer_vouches, [:voucher_id, :vouchee_id])
    create index(:peer_vouches, [:vouchee_id])
    create index(:peer_vouches, [:city])
    create index(:peer_vouches, [:inserted_at])

    create constraint(:peer_vouches, :peer_vouches_no_self, check: "voucher_id <> vouchee_id")
  end
end

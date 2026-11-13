defmodule Marrylocal.Repo.Migrations.AddPeerVouchingToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :peer_verified, :boolean, default: false, null: false
      add :peer_vouches_received, :integer, default: 0, null: false
      add :vouch_credits_remaining, :integer, default: 0, null: false
    end

    create constraint(:users, :users_peer_vouches_received_non_negative,
             check: "peer_vouches_received >= 0"
           )

    create constraint(:users, :users_vouch_credits_non_negative,
             check: "vouch_credits_remaining >= 0"
           )
  end
end

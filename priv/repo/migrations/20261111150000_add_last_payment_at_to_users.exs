defmodule Marrylocal.Repo.Migrations.AddLastPaymentAtToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :last_payment_at, :utc_datetime
    end
  end
end

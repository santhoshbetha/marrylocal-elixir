defmodule Marrylocal.Repo.Migrations.AddPaymentLifecycle do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :force_verification_required, :boolean, null: false, default: false
      add :date_of_last_payment, :date
    end

    create table(:transactions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :order_id, :string, null: false
      add :provider_transaction_id, :string
      add :provider, :string, null: false, default: "phonepe"
      add :status, :string, null: false, default: "pending"
      add :amount, :integer, null: false
      add :currency, :string, null: false, default: "INR"
      add :payment_method, :string
      add :invoice_key, :string
      add :metadata, :map, null: false, default: %{}
      add :paid_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:transactions, [:order_id])
    create index(:transactions, [:user_id])
    create index(:transactions, [:status])

    create constraint(:transactions, :transactions_status_check,
             check: "status IN ('pending', 'success', 'failed')"
           )
  end
end

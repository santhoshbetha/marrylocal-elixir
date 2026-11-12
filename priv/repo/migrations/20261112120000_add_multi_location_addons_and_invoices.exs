defmodule Marrylocal.Repo.Migrations.AddMultiLocationAddonsAndInvoices do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :location_2_state, :string
      add :location_2_city, :string
      add :location_2_last_changed_at, :utc_datetime
      add :location_2_purchased_at, :utc_datetime
      add :location_2_expires_at, :utc_datetime

      add :location_3_state, :string
      add :location_3_city, :string
      add :location_3_last_changed_at, :utc_datetime
      add :location_3_purchased_at, :utc_datetime
      add :location_3_expires_at, :utc_datetime
    end

    execute """
    ALTER TABLE users
      ADD COLUMN IF NOT EXISTS location_2_geom geography(Point, 4326),
      ADD COLUMN IF NOT EXISTS location_3_geom geography(Point, 4326)
    """

    create index(:users, [:location_2_expires_at])
    create index(:users, [:location_3_expires_at])

    create table(:invoices) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :invoice_number, :string, null: false
      add :item_type, :string, null: false
      add :description, :string, null: false
      add :base_amount_inr, :decimal, precision: 12, scale: 2, null: false, default: 0
      add :gst_amount_inr, :decimal, precision: 12, scale: 2, null: false, default: 0
      add :total_amount_inr, :decimal, precision: 12, scale: 2, null: false, default: 0
      add :period_start, :utc_datetime
      add :period_end, :utc_datetime
      add :payment_reference, :string
      add :pdf_url, :string
      add :status, :string, null: false, default: "paid"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invoices, [:invoice_number])
    create index(:invoices, [:user_id])
    create index(:invoices, [:item_type])

    create constraint(:invoices, :invoices_status_check,
             check: "status IN ('paid', 'pending', 'refunded')"
           )
  end

  def down do
    drop table(:invoices)

    execute """
    ALTER TABLE users
      DROP COLUMN IF EXISTS location_2_geom,
      DROP COLUMN IF EXISTS location_3_geom
    """

    alter table(:users) do
      remove :location_2_state
      remove :location_2_city
      remove :location_2_last_changed_at
      remove :location_2_purchased_at
      remove :location_2_expires_at
      remove :location_3_state
      remove :location_3_city
      remove :location_3_last_changed_at
      remove :location_3_purchased_at
      remove :location_3_expires_at
    end
  end
end

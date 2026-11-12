defmodule Marrylocal.Billing.Invoice do
  @moduledoc "An itemized invoice for an annual fee or a monthly addon subscription."

  use Ecto.Schema
  import Ecto.Changeset

  schema "invoices" do
    field :invoice_number, :string
    field :item_type, :string
    field :description, :string
    field :base_amount_inr, :decimal, default: Decimal.new("0")
    field :gst_amount_inr, :decimal, default: Decimal.new("0")
    field :total_amount_inr, :decimal, default: Decimal.new("0")
    field :period_start, :utc_datetime
    field :period_end, :utc_datetime
    field :payment_reference, :string
    field :pdf_url, :string
    field :status, :string, default: "paid"

    belongs_to :user, Marrylocal.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @required [
    :user_id,
    :invoice_number,
    :item_type,
    :description,
    :base_amount_inr,
    :gst_amount_inr,
    :total_amount_inr,
    :status
  ]

  def changeset(invoice, attrs) do
    invoice
    |> cast(
      attrs,
      @required ++
        [
          :period_start,
          :period_end,
          :payment_reference,
          :pdf_url
        ]
    )
    |> validate_required(@required)
    |> validate_inclusion(:status, ~w(paid pending refunded))
    |> unique_constraint(:invoice_number)
    |> check_constraint(:status, name: :invoices_status_check)
  end
end

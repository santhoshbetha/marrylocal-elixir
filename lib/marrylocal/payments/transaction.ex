defmodule Marrylocal.Payments.Transaction do
  @moduledoc "A server-owned payment transaction and its generated invoice."

  use Ecto.Schema
  use Waffle.Ecto.Schema

  import Ecto.Changeset

  alias Marrylocal.Accounts.User
  alias Marrylocal.Uploaders.Invoice

  schema "transactions" do
    field :order_id, :string
    field :provider_transaction_id, :string
    field :provider, :string, default: "phonepe"
    field :status, :string, default: "pending"
    field :amount, :integer
    field :currency, :string, default: "INR"
    field :payment_method, :string
    field :invoice_key, Invoice.Type
    field :metadata, :map, default: %{}
    field :paid_at, :utc_datetime

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [
      :user_id,
      :order_id,
      :provider_transaction_id,
      :provider,
      :status,
      :amount,
      :currency,
      :payment_method,
      :metadata,
      :paid_at
    ])
    |> validate_required([:user_id, :order_id, :amount, :status])
    |> unique_constraint(:order_id)
    |> check_constraint(:status, name: :transactions_status_check)
  end

  def invoice_changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [:invoice_key])
    |> cast_attachments(attrs, [:invoice_key])
    |> validate_required([:invoice_key])
  end

  def invoice_url(%__MODULE__{invoice_key: nil}), do: nil
  def invoice_url(%__MODULE__{invoice_key: ""}), do: nil

  def invoice_url(%__MODULE__{invoice_key: key} = transaction) do
    Invoice.url({key, transaction})
  rescue
    _ -> nil
  end
end

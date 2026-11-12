defmodule Marrylocal.Payments do
  @moduledoc """
  Server-owned PhonePe transaction ledger, service-fee pricing, and invoice
  activation lifecycle.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Marrylocal.Accounts.User
  alias Marrylocal.Notifications
  alias Marrylocal.Payments.Transaction
  alias Marrylocal.Repo
  alias Marrylocal.Workers.InvoiceWorker

  @base_service_fee 500
  @gst_rate 0.18
  @referral_credit 50

  @doc "Calculates the annual service fee entirely on the server."
  def service_fee(%User{} = user) do
    base = user.accepted_one_time_fees_amount || @base_service_fee
    discount = min((user.referral_credits_count || 0) * @referral_credit, base)
    subtotal = max(base - discount, 0)
    gst = round(subtotal * @gst_rate)
    total = subtotal + gst

    %{
      base_inr: base,
      discount_inr: discount,
      subtotal_inr: subtotal,
      gst_inr: gst,
      total_inr: total,
      total_paise: total * 100
    }
  end

  def create_pending_transaction(%User{} = user, %{order_id: order_id, amount: amount} = order) do
    %Transaction{}
    |> Transaction.changeset(%{
      user_id: user.id,
      order_id: order_id,
      amount: amount,
      currency: "INR",
      status: "pending",
      metadata: %{
        "payload" => Map.get(order, :payload, %{})
      }
    })
    |> Repo.insert()
  end

  def list_transactions(user_id) do
    from(t in Transaction,
      where: t.user_id == ^user_id,
      order_by: [desc: t.inserted_at]
    )
    |> Repo.all()
  end

  def get_for_user(order_id, user_id) do
    Repo.get_by(Transaction, order_id: order_id, user_id: user_id)
  end

  def get(order_id), do: Repo.get_by(Transaction, order_id: order_id)

  @doc """
  Atomically applies a verified PhonePe callback and schedules the invoice job.
  """
  def complete_from_callback(decoded) when is_map(decoded) do
    data = decoded["data"] || %{}
    order_id = data["merchantTransactionId"] || data["transactionId"]
    success? = decoded["code"] == "PAYMENT_SUCCESS" or data["state"] == "COMPLETED"

    case get(order_id) do
      nil ->
        {:error, :transaction_not_found}

      %Transaction{} = transaction ->
        result =
          Repo.transaction(fn ->
            {:ok, updated} =
              transaction
              |> Transaction.changeset(%{
                status: if(success?, do: "success", else: "failed"),
                provider_transaction_id: data["transactionId"],
                payment_method: get_in(data, ["paymentInstrument", "type"]),
                paid_at:
                  if(success?, do: DateTime.utc_now() |> DateTime.truncate(:second), else: nil),
                metadata: Map.merge(transaction.metadata || %{}, %{"callback" => decoded})
              })
              |> Repo.update()

            if success? do
              {:ok, _user} =
                Repo.get!(User, updated.user_id)
                |> Ecto.Changeset.change(%{
                  onetime_fees_paid: true,
                  date_of_last_payment: Date.utc_today(),
                  last_payment_at: DateTime.utc_now() |> DateTime.truncate(:second)
                })
                |> Repo.update()

              {:ok, notification} =
                Notifications.insert_notification(%{
                  user_id: updated.user_id,
                  type: :system,
                  title: "Payment received",
                  body:
                    "Your annual service fee payment was successful. Your invoice is being generated."
                })

              {updated, notification}
            else
              {updated, nil}
            end
          end)

        case result do
          {:ok, {updated, notification}} ->
            if updated.status == "success" do
              Notifications.broadcast_many([notification])
              _ = Oban.insert(InvoiceWorker.new(%{"transaction_id" => updated.id}))
            end

            {:ok, updated}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def complete_from_callback(_decoded), do: {:error, :invalid_callback}
end

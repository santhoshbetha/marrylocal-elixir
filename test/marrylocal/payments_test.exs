defmodule Marrylocal.PaymentsTest do
  use Marrylocal.DataCase

  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts.User
  alias Marrylocal.Payments
  alias Marrylocal.Repo

  test "calculates service fees and referral credits on the server" do
    user =
      user_fixture()
      |> Ecto.Changeset.change(%{
        accepted_one_time_fees_amount: 500,
        referral_credits_count: 2
      })
      |> Repo.update!()

    pricing = Payments.service_fee(user)

    assert pricing.base_inr == 500
    assert pricing.discount_inr == 100
    assert pricing.subtotal_inr == 400
    assert pricing.gst_inr == 72
    assert pricing.total_inr == 472
    assert pricing.total_paise == 47_200
  end

  test "a verified callback activates the fee and records the transaction atomically" do
    user =
      user_fixture()
      |> Ecto.Changeset.change(%{accepted_one_time_fees_amount: 500, referral_credits_count: 0})
      |> Repo.update!()

    pricing = Payments.service_fee(user)
    order_id = "MLTEST#{System.unique_integer([:positive])}"

    assert {:ok, transaction} =
             Payments.create_pending_transaction(user, %{
               order_id: order_id,
               amount: pricing.total_paise,
               payload: %{"merchantTransactionId" => order_id}
             })

    decoded = %{
      "code" => "PAYMENT_SUCCESS",
      "data" => %{
        "merchantTransactionId" => order_id,
        "transactionId" => "PP-123",
        "state" => "COMPLETED",
        "paymentInstrument" => %{"type" => "PAY_PAGE"}
      }
    }

    assert {:ok, updated} = Payments.complete_from_callback(decoded)
    assert updated.id == transaction.id
    assert updated.status == "success"

    refreshed_user = Repo.get!(User, user.id)
    assert refreshed_user.onetime_fees_paid == true
    assert refreshed_user.date_of_last_payment == Date.utc_today()
    assert %DateTime{} = refreshed_user.last_payment_at
  end
end

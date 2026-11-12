defmodule Marrylocal.PaymentGateTest do
  use Marrylocal.DataCase

  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts
  alias Marrylocal.Accounts.User
  alias Marrylocal.Features
  alias Marrylocal.Repo
  alias Marrylocal.Workers.YearlySubscriptionReset

  setup do
    previous = Application.get_env(:marrylocal, :features)

    on_exit(fn ->
      Application.put_env(:marrylocal, :features, previous || [])
    end)

    :ok
  end

  defp insert_city_users(city, count) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    offset = System.unique_integer([:positive])

    rows =
      for index <- 1..count do
        %{
          email: "paygate-#{offset}-#{index}@example.com",
          phone_number:
            "+9194#{String.pad_leading(Integer.to_string(offset * 1_000 + index), 8, "0")}",
          first_name: "City",
          last_name: "Member",
          user_handle: "paygate_#{offset}_#{index}",
          referral_code: "PG#{offset}#{String.pad_leading(Integer.to_string(index), 6, "0")}",
          gender: "Male",
          user_state: :active,
          city: city,
          state: "Delhi",
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(User, rows)
  end

  test "the 250-city threshold sets the fee flag and never clears an admin override" do
    viewer = user_fixture(%{gender: "Female", city: "Pune"})

    insert_city_users("Pune", 250)
    assert {:ok, at_threshold} = Accounts.evaluate_gating(viewer)
    refute at_threshold.onetime_fees_required

    insert_city_users("Pune", 1)
    assert {:ok, over_threshold} = Accounts.evaluate_gating(at_threshold)
    assert over_threshold.onetime_fees_required

    admin_override =
      user_fixture(%{gender: "Female", city: "Mumbai"})
      |> Ecto.Changeset.change(onetime_fees_required: true)
      |> Repo.update!()

    assert {:ok, preserved_true} = Accounts.evaluate_gating(admin_override)
    assert preserved_true.onetime_fees_required
  end

  test "master payment gate takes precedence and excludes admins" do
    user =
      user_fixture()
      |> Ecto.Changeset.change(%{
        onetime_fees_required: true,
        onetime_fees_paid: false
      })
      |> Repo.update!()

    admin =
      user_fixture()
      |> Ecto.Changeset.change(%{
        role: :admin,
        onetime_fees_required: true,
        onetime_fees_paid: false
      })
      |> Repo.update!()

    Features.put_enforce_payment_gate(false)
    refute Features.payment_enforcement_active?(user)

    Features.put_enforce_payment_gate(true)
    assert Features.payment_enforcement_active?(user)
    refute Features.payment_enforcement_active?(admin)

    paid =
      user
      |> Ecto.Changeset.change(onetime_fees_paid: true)
      |> Repo.update!()

    refute Features.payment_enforcement_active?(paid)
  end

  test "annual reset clears paid access after 365 days" do
    old = DateTime.utc_now() |> DateTime.add(-400, :day) |> DateTime.truncate(:second)
    recent = DateTime.utc_now() |> DateTime.add(-20, :day) |> DateTime.truncate(:second)

    expired =
      user_fixture()
      |> Ecto.Changeset.change(%{
        onetime_fees_paid: true,
        onetime_fees_required: true,
        last_payment_at: old,
        date_of_last_payment: DateTime.to_date(old)
      })
      |> Repo.update!()

    active =
      user_fixture()
      |> Ecto.Changeset.change(%{
        onetime_fees_paid: true,
        onetime_fees_required: true,
        last_payment_at: recent,
        date_of_last_payment: DateTime.to_date(recent)
      })
      |> Repo.update!()

    assert :ok = YearlySubscriptionReset.perform(%Oban.Job{})

    expired_after = Repo.get!(User, expired.id)
    active_after = Repo.get!(User, active.id)

    refute expired_after.onetime_fees_paid
    assert expired_after.onetime_fees_required
    assert active_after.onetime_fees_paid
  end

  test "login-time gating expires a payment older than 365 days" do
    expired_at =
      DateTime.utc_now() |> DateTime.add(-366, :day) |> DateTime.truncate(:second)

    user =
      user_fixture()
      |> Ecto.Changeset.change(%{
        onetime_fees_paid: true,
        onetime_fees_required: true,
        last_payment_at: expired_at,
        date_of_last_payment: DateTime.to_date(expired_at)
      })
      |> Repo.update!()

    assert {:ok, refreshed} = Accounts.evaluate_gating(user)
    refute refreshed.onetime_fees_paid
    assert refreshed.onetime_fees_required
  end
end

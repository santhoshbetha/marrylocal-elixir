defmodule Marrylocal.VerificationGateTest do
  use Marrylocal.DataCase

  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts
  alias Marrylocal.Accounts.User
  alias Marrylocal.Features
  alias Marrylocal.Geo
  alias Marrylocal.Repo

  setup do
    previous = Application.get_env(:marrylocal, :features)

    on_exit(fn ->
      Application.put_env(:marrylocal, :features, previous || [])
    end)

    :ok
  end

  test "enforces verification only when the master gate is enabled" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    old = DateTime.add(now, -8, :day)

    viewer =
      user_fixture(%{gender: "Female", city: "Delhi"})
      |> Ecto.Changeset.change(%{
        inserted_at: old,
        latitude: 28.6139,
        longitude: 77.2090,
        location: Geo.point(28.6139, 77.2090)
      })
      |> Repo.update!()

    for index <- 1..51 do
      %User{
        email: "gate-near-#{index}-#{System.unique_integer([:positive])}@example.com",
        phone_number: "+9197#{String.pad_leading(Integer.to_string(index), 8, "0")}",
        referral_code: "GATE#{String.pad_leading(Integer.to_string(index), 6, "0")}",
        first_name: "Near",
        last_name: "Member",
        gender: "Male",
        user_state: :active,
        city: "Delhi",
        state: "Delhi",
        latitude: 28.6140,
        longitude: 77.2091,
        location: Geo.point(28.6140, 77.2091),
        inserted_at: now,
        updated_at: now
      }
      |> Repo.insert!()
    end

    Features.put_enforce_verification_gate(false)
    assert {:ok, ungated} = Accounts.evaluate_gating(viewer)
    assert ungated.around_user_count == 51
    refute ungated.force_verification_required

    Features.put_enforce_verification_gate(true)
    assert {:ok, gated} = Accounts.evaluate_gating(ungated)
    assert gated.force_verification_required

    verified =
      gated
      |> Ecto.Changeset.change(aadhar_verified: true)
      |> Repo.update!()

    assert {:ok, verified_result} = Accounts.evaluate_gating(verified)
    refute verified_result.force_verification_required

    peer_verified =
      gated
      |> Ecto.Changeset.change(
        peer_verified: true,
        peer_vouches_received: 3,
        vouch_credits_remaining: 5
      )
      |> Repo.update!()

    assert {:ok, peer_result} = Accounts.evaluate_gating(peer_verified)
    refute peer_result.force_verification_required

    fresh =
      verified_result
      |> Ecto.Changeset.change(inserted_at: now)
      |> Repo.update!()

    assert {:ok, fresh_result} = Accounts.evaluate_gating(fresh)
    refute fresh_result.force_verification_required
  end
end

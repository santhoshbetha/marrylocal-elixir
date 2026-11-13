defmodule Marrylocal.Verification.PeerVouchTest do
  use Marrylocal.DataCase, async: false

  import Ecto.Query
  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts.User
  alias Marrylocal.Repo
  alias Marrylocal.Verification.PeerVouch
  alias Marrylocal.Verification.PeerVouchService
  alias Marrylocal.Verification.VouchCache

  setup do
    vouchee = active_user(%{city: "Delhi", state: "Delhi"})

    verifiers =
      for index <- 1..3 do
        active_user(%{
          city: "Delhi",
          state: "Delhi",
          first_name: "Verifier#{index}",
          user_handle:
            "pv#{index}#{String.pad_leading(Integer.to_string(rem(System.unique_integer([:positive]), 1_000_000)), 6, "0")}"
        })
        |> make_verifier()
      end

    {:ok, vouchee: vouchee, verifiers: verifiers}
  end

  test "tokens are single-use", %{vouchee: vouchee} do
    token = VouchCache.generate_token(vouchee.id)
    vouchee_id = vouchee.id

    assert {:ok, ^vouchee_id} = VouchCache.consume_token(token)
    assert {:error, :token_invalid} = VouchCache.consume_token(token)
    assert {:error, :token_invalid} = VouchCache.consume_token("not-a-real-token")
  end

  test "expired tokens are reported separately from invalid tokens", %{vouchee: vouchee} do
    token = VouchCache.generate_token(vouchee.id)
    expired_at = System.monotonic_time(:millisecond) - 1
    :ets.insert(VouchCache, {token, vouchee.id, expired_at})

    assert {:error, :token_expired} = VouchCache.consume_token(token)
    assert {:error, :token_invalid} = VouchCache.consume_token(token)
  end

  test "three same-city verifiers promote the vouchee and grant five credits", %{
    vouchee: vouchee,
    verifiers: [first, second, third]
  } do
    assert {:ok, result} = PeerVouchService.process_peer_vouch(first.id, vouchee.id)
    assert result.current_vouches == 1
    refute result.peer_verified
    assert result.voucher.vouch_credits_remaining == 4

    assert {:ok, result} = PeerVouchService.process_peer_vouch(second.id, vouchee.id)
    assert result.current_vouches == 2
    refute result.peer_verified

    assert {:ok, result} = PeerVouchService.process_peer_vouch(third.id, vouchee.id)
    assert result.current_vouches == 3
    assert result.peer_verified
    assert result.vouch_credits_remaining == 5

    updated = Repo.get!(User, vouchee.id)
    assert updated.peer_verified
    assert updated.peer_vouches_received == 3
    assert updated.vouch_credits_remaining == 5

    assert Repo.aggregate(from(v in PeerVouch, where: v.vouchee_id == ^vouchee.id), :count) == 3

    assert {:error, :duplicate_vouch} =
             PeerVouchService.process_peer_vouch(first.id, vouchee.id)
  end

  test "rejects self-vouching, inactive users, city mismatch, and exhausted credits", %{
    vouchee: vouchee,
    verifiers: [voucher, other | _]
  } do
    assert {:error, :self_vouch} = PeerVouchService.process_peer_vouch(voucher.id, voucher.id)

    inactive = active_user(%{city: "Delhi", state: "Delhi", user_state: :inactive})
    assert {:error, :inactive_user} = PeerVouchService.process_peer_vouch(voucher.id, inactive.id)

    mumbai = active_user(%{city: "Mumbai", state: "Maharashtra"})
    assert {:error, :city_mismatch} = PeerVouchService.process_peer_vouch(voucher.id, mumbai.id)

    {:ok, broke} =
      other
      |> Ecto.Changeset.change(vouch_credits_remaining: 0)
      |> Repo.update()

    assert {:error, :no_vouch_credits} =
             PeerVouchService.process_peer_vouch(broke.id, vouchee.id)

    assert {:error, :inactive_user} =
             PeerVouchService.process_peer_vouch(
               voucher.id,
               active_user(%{city: "Delhi", state: "Delhi", user_state: :inactive}).id
             )
  end

  defp active_user(attrs) do
    user_fixture(attrs)
    |> Ecto.Changeset.change(user_state: Map.get(attrs, :user_state, :active))
    |> Repo.update!()
  end

  defp make_verifier(user) do
    user
    |> Ecto.Changeset.change(peer_verified: true, vouch_credits_remaining: 5)
    |> Repo.update!()
  end
end

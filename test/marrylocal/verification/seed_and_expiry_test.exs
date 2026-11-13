defmodule Marrylocal.Verification.SeedAndExpiryTest do
  use Marrylocal.DataCase, async: false
  use Oban.Testing, repo: Marrylocal.Repo

  import Ecto.Query

  alias Marrylocal.Accounts.IdentityVerification
  alias Marrylocal.Accounts.User
  alias Marrylocal.Accounts.Verifications
  alias Marrylocal.Repo
  alias Marrylocal.Workers.CitySeedRecruitmentWorker
  alias Marrylocal.Workers.VerificationExpiryWorker

  test "invites at most ten seed candidates per city and refills an opted-out slot" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for index <- 1..12 do
      insert_active("Hyderabad", "Telangana", index, now)
    end

    insert_active("Mumbai", "Maharashtra", 99, now)

    assert :ok =
             perform_job(CitySeedRecruitmentWorker, %{
               "city" => "Hyderabad",
               "state" => "Telangana"
             })

    invited = invited_users()
    assert length(invited) == 10
    assert Enum.all?(invited, &(&1.city == "Hyderabad"))

    # Idempotent while ten invitations are outstanding.
    assert :ok =
             perform_job(CitySeedRecruitmentWorker, %{
               "city" => "Hyderabad",
               "state" => "Telangana"
             })

    assert length(invited_users()) == 10

    # Opting out frees one slot and the next eligible member is invited.
    [opted_out | _] = invited

    opted_out
    |> Ecto.Changeset.change(seed_verifier_status: "opted_out")
    |> Repo.update!()

    assert :ok =
             perform_job(CitySeedRecruitmentWorker, %{
               "city" => "Hyderabad",
               "state" => "Telangana"
             })

    assert length(invited_users()) == 10

    assert Repo.aggregate(
             from(u in User, where: u.seed_verifier_status == "opted_out"),
             :count,
             :id
           ) == 1
  end

  test "the sweep fills every city when no args are given" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for index <- 1..3 do
      insert_active("Kochi", "Kerala", index, now)
      insert_active("Jaipur", "Rajasthan", index + 20, now)
    end

    assert :ok = perform_job(CitySeedRecruitmentWorker, %{})

    counts =
      Repo.all(
        from(u in User,
          where: u.seed_verifier_status == "invited",
          group_by: u.city,
          select: {u.city, count(u.id)}
        )
      )
      |> Map.new()

    assert counts["Kochi"] == 3
    assert counts["Jaipur"] == 3
  end

  test "expires verification after the configured validity window" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expired = insert_verified_user("Delhi", "Delhi", 301, DateTime.add(now, -731, :day), now)
    valid = insert_verified_user("Delhi", "Delhi", 302, DateTime.add(now, -729, :day), now)

    assert :ok = perform_job(VerificationExpiryWorker, %{})

    refreshed = Repo.get!(User, expired.id)
    refute refreshed.peer_verified
    refute refreshed.is_peer_verifier
    assert refreshed.peer_vouches_received == 0
    assert refreshed.vouch_credits_remaining == 0
    assert is_nil(refreshed.verified_at)
    refute refreshed.passport_verified
    assert refreshed.seed_verifier_status == "none"

    assert Repo.get!(User, valid.id).peer_verified

    assert Repo.one(
             from(v in IdentityVerification,
               where: v.user_id == ^expired.id,
               select: v.status
             )
           ) == "expired"
  end

  test "an explicit validity_days argument overrides the global setting" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    user = insert_verified_user("Delhi", "Delhi", 303, DateTime.add(now, -400, :day), now)

    assert :ok = perform_job(VerificationExpiryWorker, %{"validity_days" => 365})
    refute Repo.get!(User, user.id).peer_verified
  end

  test "approving an opted-in seed candidate promotes them to verifier" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    user =
      insert_active("Hyderabad", "Telangana", 401, now)
      |> Ecto.Changeset.change(seed_verifier_status: "opted_in")
      |> Repo.update!()

    verification =
      Repo.insert!(%IdentityVerification{
        user_id: user.id,
        document_type: "passport",
        document_number: "P#{System.unique_integer([:positive])}",
        identity_hash: "seed-hash-#{System.unique_integer([:positive])}",
        document_image: %{file_name: "", updated_at: nil},
        status: "pending_admin_review"
      })
      |> Repo.preload(:user)

    assert {:ok, _updated} = Verifications.approve(verification)

    refreshed = Repo.get!(User, user.id)
    assert refreshed.passport_verified
    assert refreshed.seed_verifier_status == "approved"
    assert refreshed.peer_verified
    assert refreshed.is_peer_verifier
    assert refreshed.vouch_credits_remaining == 5
    assert refreshed.verified_at
  end

  defp invited_users do
    Repo.all(from(u in User, where: u.seed_verifier_status == "invited"))
  end

  defp insert_active(city, state, index, now) do
    unique =
      System.unique_integer([:positive])
      |> Integer.to_string()
      |> String.pad_leading(9, "0")
      |> String.slice(-9, 9)

    %User{
      email: "seed-#{city}-#{index}-#{System.unique_integer([:positive])}@example.com",
      phone_number: "+9198#{unique}",
      referral_code: "SEED#{unique}",
      first_name: "Seed",
      last_name: "Member",
      gender: if(rem(index, 2) == 0, do: "Female", else: "Male"),
      user_state: :active,
      city: city,
      state: state,
      inserted_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp insert_verified_user(city, state, index, verified_at, now) do
    user =
      insert_active(city, state, index, now)
      |> Ecto.Changeset.change(
        peer_verified: true,
        peer_vouches_received: 3,
        is_peer_verifier: true,
        vouch_credits_remaining: 5,
        seed_verifier_status: "approved",
        passport_verified: true,
        verified_at: verified_at
      )
      |> Repo.update!()

    Repo.insert!(%IdentityVerification{
      user_id: user.id,
      document_type: "passport",
      document_number: "P#{System.unique_integer([:positive])}",
      identity_hash: "expiry-hash-#{System.unique_integer([:positive])}",
      document_image: %{file_name: "", updated_at: nil},
      status: "verified"
    })

    user
  end
end

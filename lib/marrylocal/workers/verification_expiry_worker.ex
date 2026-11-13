defmodule Marrylocal.Workers.VerificationExpiryWorker do
  @moduledoc """
  Daily sweep that expires trust badges after the configured validity window.

  Defaults to `Features.verification_validity_days/0` (730 days). Expired
  members lose their peer and government-ID verification flags, vouch credits,
  and verifier role so they must re-verify. Seed-recruitment states are reset so
  the city pipeline can invite them again.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query, warn: false

  alias Marrylocal.Accounts.IdentityVerification
  alias Marrylocal.Accounts.User
  alias Marrylocal.Features
  alias Marrylocal.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    days = validity_days(args)
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day) |> DateTime.truncate(:second)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ids =
      from(u in User,
        where: not is_nil(u.verified_at) and u.verified_at < ^cutoff,
        select: u.id
      )
      |> Repo.all()

    if ids != [] do
      from(u in User, where: u.id in ^ids)
      |> Repo.update_all(
        set: [
          peer_verified: false,
          peer_vouches_received: 0,
          is_peer_verifier: false,
          vouch_credits_remaining: 0,
          is_available_to_vouch: true,
          aadhar_verified: false,
          passport_verified: false,
          license_verified: false,
          verified_at: nil,
          updated_at: now
        ]
      )

      from(u in User,
        where:
          u.id in ^ids and
            u.seed_verifier_status in ["invited", "opted_in", "approved"]
      )
      |> Repo.update_all(set: [seed_verifier_status: "none", updated_at: now])

      from(v in IdentityVerification,
        where: v.user_id in ^ids and v.status == "verified"
      )
      |> Repo.update_all(set: [status: "expired", updated_at: now])
    end

    :ok
  end

  defp validity_days(%{"validity_days" => days}) when is_integer(days) and days > 0, do: days
  defp validity_days(_args), do: Features.verification_validity_days()
end

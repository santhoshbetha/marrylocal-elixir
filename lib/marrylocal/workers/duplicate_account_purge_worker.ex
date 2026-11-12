defmodule Marrylocal.Workers.DuplicateAccountPurgeWorker do
  @moduledoc """
  Removes unverified duplicate accounts that share a verified member's photo
  fingerprint. Phone numbers are already protected by a unique index, but this
  worker also checks the phone for legacy data safety.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Marrylocal.Accounts.{User, UserPhotoHash}
  alias Marrylocal.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case Repo.get(User, user_id) do
      nil ->
        :ok

      %User{} = verified ->
        if verified_user?(verified) do
          purge_duplicates(verified)
        end

        :ok
    end
  end

  defp purge_duplicates(verified) do
    hashes =
      from(h in UserPhotoHash,
        where: h.user_id == ^verified.id and h.active == true,
        select: h.photo_hash
      )
      |> Repo.all()

    candidate_ids =
      from(h in UserPhotoHash,
        where: h.photo_hash in ^hashes and h.active == true and h.user_id != ^verified.id,
        select: h.user_id
      )
      |> Repo.all()
      |> Enum.uniq()

    legacy_phone_ids =
      if is_binary(verified.phone_number) and verified.phone_number != "" do
        from(u in User,
          where:
            u.id != ^verified.id and u.phone_number == ^verified.phone_number and
              u.user_state == :active,
          select: u.id
        )
        |> Repo.all()
      else
        []
      end

    (candidate_ids ++ legacy_phone_ids)
    |> Enum.uniq()
    |> Enum.each(fn id ->
      case Repo.get(User, id) do
        %User{} = duplicate ->
          if deletable_duplicate?(duplicate) do
            Logger.warning("Purging duplicate unverified account #{duplicate.id}")
            Repo.delete(duplicate)
          end

        nil ->
          :ok
      end
    end)
  end

  defp deletable_duplicate?(%User{} = user) do
    user.role != :admin and user.user_state != :deleted and not verified_user?(user) and
      not user.sample_profile
  end

  defp verified_user?(%User{} = user) do
    user.aadhar_verified or user.passport_verified or user.license_verified
  end
end

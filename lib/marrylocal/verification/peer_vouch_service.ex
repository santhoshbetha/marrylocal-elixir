defmodule Marrylocal.Verification.PeerVouchService do
  @moduledoc """
  Atomic peer-to-peer verification transaction.

  All policy checks run inside the same `Ecto.Multi` as the insert and counter
  updates. The unique `(voucher_id, vouchee_id)` index is the final guard against
  concurrent duplicate vouches.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Marrylocal.Accounts.User
  alias Marrylocal.Repo
  alias Marrylocal.Verification.PeerVouch

  @required_vouches 3
  @verifier_credit_grant 5

  @type error_reason ::
          :self_vouch
          | :user_not_found
          | :inactive_user
          | :voucher_not_verified
          | :no_vouch_credits
          | :vouchee_already_verified
          | :vouchee_vouch_limit_reached
          | :city_mismatch
          | :duplicate_vouch
          | Ecto.Changeset.t()
          | term()

  @doc """
  Records one vouch from `voucher_id` to `vouchee_id`.

  Returns `{:ok, result}` with the updated vouchee, current count, peer status,
  and remaining credits, or `{:error, reason}`.
  """
  @spec process_peer_vouch(integer(), integer()) :: {:ok, map()} | {:error, error_reason()}
  def process_peer_vouch(voucher_id, vouchee_id)
      when is_integer(voucher_id) and is_integer(vouchee_id) do
    Multi.new()
    |> Multi.run(:context, fn repo, _changes ->
      validate(repo, voucher_id, vouchee_id)
    end)
    |> Multi.insert(:vouch, fn %{context: %{voucher: voucher, vouchee: vouchee}} ->
      PeerVouch.changeset(%PeerVouch{}, %{
        voucher_id: voucher.id,
        vouchee_id: vouchee.id,
        city: vouchee.city
      })
    end)
    |> Multi.run(:debit_voucher, fn repo, %{context: %{voucher: voucher}} ->
      query =
        from(u in User,
          where: u.id == ^voucher.id and u.vouch_credits_remaining > 0
        )

      case repo.update_all(query, inc: [vouch_credits_remaining: -1]) do
        {1, _rows} -> {:ok, :debited}
        _ -> {:error, :no_vouch_credits}
      end
    end)
    |> Multi.run(:credit_vouchee, fn repo, %{context: %{vouchee: vouchee}} ->
      query =
        from(u in User,
          where:
            u.id == ^vouchee.id and u.peer_verified == false and
              u.peer_vouches_received < ^@required_vouches
        )

      case repo.update_all(query, inc: [peer_vouches_received: 1]) do
        {1, _rows} -> {:ok, :credited}
        _ -> {:error, :vouchee_already_verified}
      end
    end)
    |> Multi.run(:promote, fn repo, %{context: %{voucher: voucher}} ->
      with %User{} = vouchee <- repo.get(User, vouchee_id) do
        vouchee_result =
          if vouchee.peer_vouches_received >= @required_vouches and not vouchee.peer_verified do
            vouchee
            |> Ecto.Changeset.change(
              peer_verified: true,
              vouch_credits_remaining: @verifier_credit_grant,
              force_verification_required: false
            )
            |> repo.update()
          else
            {:ok, vouchee}
          end

        case vouchee_result do
          {:ok, updated_vouchee} ->
            case repo.get(User, voucher.id) do
              %User{} = updated_voucher ->
                {:ok, %{vouchee: updated_vouchee, voucher: updated_voucher}}

              nil ->
                {:error, :user_not_found}
            end

          {:error, reason} ->
            {:error, reason}
        end
      else
        nil -> {:error, :user_not_found}
      end
    end)
    |> Repo.transaction()
    |> normalize_result()
  end

  def process_peer_vouch(_voucher_id, _vouchee_id), do: {:error, :user_not_found}

  defp validate(repo, voucher_id, vouchee_id) do
    if voucher_id == vouchee_id do
      {:error, :self_vouch}
    else
      with %User{} = voucher <- repo.get(User, voucher_id),
           %User{} = vouchee <- repo.get(User, vouchee_id) do
        with :ok <- ensure_active(voucher, vouchee),
             :ok <- ensure_voucher_can_vouch(voucher),
             :ok <- ensure_same_city(voucher, vouchee),
             :ok <- ensure_no_prior_vouch(repo, voucher, vouchee),
             :ok <- ensure_vouchee_needs_vouch(vouchee) do
          {:ok, %{voucher: voucher, vouchee: vouchee}}
        end
      else
        _ -> {:error, :user_not_found}
      end
    end
  end

  defp ensure_active(voucher, vouchee) do
    if voucher.user_state == :active and vouchee.user_state == :active do
      :ok
    else
      {:error, :inactive_user}
    end
  end

  defp ensure_voucher_can_vouch(%User{peer_verified: true, vouch_credits_remaining: credits})
       when is_integer(credits) and credits > 0,
       do: :ok

  defp ensure_voucher_can_vouch(%User{peer_verified: false}), do: {:error, :voucher_not_verified}

  defp ensure_voucher_can_vouch(_voucher), do: {:error, :no_vouch_credits}

  defp ensure_vouchee_needs_vouch(%User{peer_verified: true}),
    do: {:error, :vouchee_already_verified}

  defp ensure_vouchee_needs_vouch(%User{peer_vouches_received: received})
       when is_integer(received) and received >= @required_vouches,
       do: {:error, :vouchee_vouch_limit_reached}

  defp ensure_vouchee_needs_vouch(_vouchee), do: :ok

  defp ensure_same_city(%User{city: voucher_city}, %User{city: vouchee_city})
       when is_binary(voucher_city) and is_binary(vouchee_city) do
    if String.downcase(String.trim(voucher_city)) == String.downcase(String.trim(vouchee_city)) do
      :ok
    else
      {:error, :city_mismatch}
    end
  end

  defp ensure_same_city(_voucher, _vouchee), do: {:error, :city_mismatch}

  defp ensure_no_prior_vouch(repo, voucher, vouchee) do
    case repo.get_by(PeerVouch, voucher_id: voucher.id, vouchee_id: vouchee.id) do
      nil -> :ok
      _existing -> {:error, :duplicate_vouch}
    end
  end

  defp normalize_result({:ok, %{promote: %{vouchee: vouchee, voucher: voucher}}}) do
    {:ok,
     %{
       vouchee: vouchee,
       voucher: voucher,
       current_vouches: vouchee.peer_vouches_received,
       peer_verified: vouchee.peer_verified,
       vouch_credits_remaining: vouchee.vouch_credits_remaining
     }}
  end

  defp normalize_result({:error, :context, reason, _changes}), do: {:error, reason}

  defp normalize_result({:error, :vouch, %Ecto.Changeset{} = changeset, _changes}) do
    if changeset.errors[:voucher_id] || changeset.errors[:vouchee_id] do
      {:error, :duplicate_vouch}
    else
      {:error, changeset}
    end
  end

  defp normalize_result({:error, :debit_voucher, reason, _changes}), do: {:error, reason}

  defp normalize_result({:error, :credit_vouchee, reason, _changes}), do: {:error, reason}

  defp normalize_result({:error, :promote, reason, _changes}), do: {:error, reason}

  defp normalize_result({:error, _step, reason, _changes}), do: {:error, reason}
end

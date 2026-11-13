defmodule MarrylocalWeb.VouchController do
  @moduledoc """
  Peer-to-peer verification endpoints.

  Members present a 60-second single-use QR token to a peer verifier. The
  verifier scans it and the atomic `PeerVouchService` records the vouch.
  """

  use MarrylocalWeb, :controller

  import Ecto.Query, warn: false

  alias Marrylocal.Accounts
  alias Marrylocal.Accounts.User
  alias Marrylocal.Repo
  alias Marrylocal.Verification.PeerVouchService
  alias Marrylocal.Verification.VouchCache
  alias MarrylocalWeb.PeerVerificationNotifier

  @nearest_limit 5

  @doc "POST /api/v1/vouch/generate-token"
  def request_token(conn, _params) do
    user = conn.assigns.current_user
    secure_token = VouchCache.generate_token(user.id)

    json(conn, %{
      status: "success",
      secure_token: secure_token,
      expires_in: 60,
      data: %{secure_token: secure_token, expires_in: 60}
    })
  end

  @doc "POST /api/v1/vouch/verify-peer"
  def verify_peer(conn, params) do
    voucher = conn.assigns.current_user
    secure_token = params["secure_token"] || params["token"]

    with true <- is_binary(secure_token) and secure_token != "",
         {:ok, vouchee_id} <- VouchCache.consume_token(secure_token),
         {:ok, result} <- PeerVouchService.process_peer_vouch(voucher.id, vouchee_id) do
      PeerVerificationNotifier.vouch_recorded(result)

      json(conn, %{
        status: "success",
        message: "Peer vouch recorded.",
        current_vouches: result.current_vouches,
        peer_verified: result.peer_verified,
        is_peer_verifier: result.is_peer_verifier,
        vouch_credits_remaining: result.vouch_credits_remaining,
        data: %{
          current_vouches: result.current_vouches,
          peer_verified: result.peer_verified,
          is_peer_verifier: result.is_peer_verifier,
          vouch_credits_remaining: result.vouch_credits_remaining,
          vouchee: serialize_user(result.vouchee),
          voucher_credits_remaining: result.voucher.vouch_credits_remaining
        }
      })
    else
      false ->
        token_invalid(conn)

      {:error, :token_expired} ->
        conn
        |> put_status(:gone)
        |> json(%{
          status: "error",
          code: "token_expired",
          message: "This QR code has expired. Ask the member to refresh it."
        })

      {:error, :token_invalid} ->
        token_invalid(conn)

      {:error, reason} ->
        service_error(conn, reason)
    end
  end

  @doc "POST /api/v1/vouch/seed-opt-in"
  def seed_opt_in(conn, _params) do
    user = conn.assigns.current_user

    case Accounts.set_seed_verifier_status(user, "opted_in") do
      {:ok, updated} ->
        json(conn, %{
          status: "success",
          message:
            "You joined the seed verifier list. Email your government ID to verify@marrylocal.in for approval.",
          data: %{profile: %{seed_verifier_status: updated.seed_verifier_status}}
        })

      {:error, reason} ->
        seed_status_error(conn, reason)
    end
  end

  @doc "POST /api/v1/vouch/seed-opt-out"
  def seed_opt_out(conn, _params) do
    user = conn.assigns.current_user

    case Accounts.set_seed_verifier_status(user, "opted_out") do
      {:ok, updated} ->
        enqueue_seed_recruitment(updated)

        json(conn, %{
          status: "success",
          message: "You will not be invited as a seed verifier.",
          data: %{profile: %{seed_verifier_status: updated.seed_verifier_status}}
        })

      {:error, reason} ->
        seed_status_error(conn, reason)
    end
  end

  @doc "GET /api/v1/vouch/nearest-verifiers"
  def nearest_verifiers(conn, _params) do
    user = conn.assigns.current_user

    verifiers =
      if is_binary(user.city) do
        user
        |> nearest_query()
        |> Repo.all()
        |> Enum.map(&serialize_verifier/1)
      else
        []
      end

    json(conn, %{
      status: "success",
      data: %{verifiers: verifiers, count: length(verifiers), city: user.city}
    })
  end

  defp nearest_query(%User{location: nil} = user) do
    base_query(user)
    |> order_by([u], asc: u.id)
    |> select([u], %{
      id: u.id,
      first_name: u.first_name,
      last_name: u.last_name,
      hide_last_name: u.hide_last_name,
      user_handle: u.user_handle,
      city: u.city,
      allow_phone_search: u.allow_phone_search,
      show_phone: u.show_phone,
      phone_number: u.phone_number,
      vouch_credits_remaining: u.vouch_credits_remaining,
      distance_km: fragment("NULL::float8")
    })
  end

  defp nearest_query(%User{} = user) do
    base_query(user)
    |> order_by([u], fragment("ST_Distance(?, ?)", u.location, ^user.location))
    |> select([u], %{
      id: u.id,
      first_name: u.first_name,
      last_name: u.last_name,
      hide_last_name: u.hide_last_name,
      user_handle: u.user_handle,
      city: u.city,
      allow_phone_search: u.allow_phone_search,
      show_phone: u.show_phone,
      phone_number: u.phone_number,
      vouch_credits_remaining: u.vouch_credits_remaining,
      distance_km: fragment("ST_Distance(?, ?) / 1000.0", u.location, ^user.location)
    })
  end

  defp base_query(%User{} = user) do
    from(u in User,
      where:
        u.id != ^user.id and u.user_state == :active and u.is_peer_verifier == true and
          u.is_available_to_vouch == true and u.vouch_credits_remaining > 0,
      where: fragment("lower(?) = lower(?)", u.city, ^user.city),
      limit: @nearest_limit
    )
  end

  defp serialize_verifier(row) do
    phone =
      if row.allow_phone_search || row.show_phone do
        row.phone_number
      end

    %{
      id: row.id,
      first_name: row.first_name,
      last_name: display_last_name(row.last_name, row.hide_last_name),
      user_handle: row.user_handle,
      handle: row.user_handle && "@#{row.user_handle}",
      city: row.city,
      distance_km: round_distance(row.distance_km),
      vouch_credits_remaining: row.vouch_credits_remaining,
      phone_number: phone
    }
  end

  defp display_last_name(nil, _hide), do: nil

  defp display_last_name(last_name, true) do
    case String.at(last_name, 0) do
      nil -> nil
      initial -> "#{initial}."
    end
  end

  defp display_last_name(last_name, _hide), do: last_name

  defp round_distance(nil), do: nil
  defp round_distance(distance) when is_float(distance), do: Float.round(distance, 1)
  defp round_distance(distance) when is_integer(distance), do: distance / 1

  defp round_distance(%Decimal{} = distance) do
    distance
    |> Decimal.to_float()
    |> Float.round(1)
  end

  defp round_distance(_distance), do: nil

  defp serialize_user(user) do
    %{
      id: user.id,
      first_name: user.first_name,
      last_name: user.last_name,
      user_handle: user.user_handle,
      city: user.city,
      peer_verified: user.peer_verified,
      is_peer_verifier: user.is_peer_verifier,
      peer_vouches_received: user.peer_vouches_received,
      vouch_credits_remaining: user.vouch_credits_remaining
    }
  end

  defp enqueue_seed_recruitment(%User{city: city, state: state})
       when is_binary(city) and city != "" and is_binary(state) and state != "" do
    %{"city" => city, "state" => state}
    |> Marrylocal.Workers.CitySeedRecruitmentWorker.new()
    |> Oban.insert()
  end

  defp enqueue_seed_recruitment(_user), do: :ok

  defp seed_status_error(conn, %Ecto.Changeset{} = changeset) do
    errors = Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      status: "error",
      message: "Could not update seed verifier status.",
      errors: errors
    })
  end

  defp seed_status_error(conn, _reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{status: "error", message: "Could not update seed verifier status."})
  end

  defp token_invalid(conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      status: "error",
      code: "token_invalid",
      message: "This QR code is invalid or has already been scanned."
    })
  end

  defp service_error(conn, %Ecto.Changeset{} = changeset) do
    errors = Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      status: "error",
      code: "vouch_validation_failed",
      message: "This vouch could not be recorded.",
      errors: errors
    })
  end

  defp service_error(conn, reason) do
    {code, message} =
      case reason do
        :self_vouch ->
          {"self_vouch", "You cannot vouch for yourself."}

        :user_not_found ->
          {"user_not_found", "The member could not be found."}

        :inactive_user ->
          {"inactive_user", "Both accounts must be active to vouch."}

        :voucher_not_verified ->
          {"voucher_not_verified", "Only peer-verified members can vouch."}

        :no_vouch_credits ->
          {"no_vouch_credits", "You have no vouch credits remaining."}

        :vouchee_already_verified ->
          {"vouchee_already_verified", "This member is already a Peer Verifier."}

        :vouchee_vouch_limit_reached ->
          {"vouchee_vouch_limit_reached", "This member already has three peer vouches."}

        :city_mismatch ->
          {"city_mismatch", "You can only vouch for members in your city."}

        :duplicate_vouch ->
          {"duplicate_vouch", "You have already vouched for this member."}

        other ->
          {"vouch_failed", "This vouch could not be recorded: #{inspect(other)}"}
      end

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{status: "error", code: code, message: message})
  end
end

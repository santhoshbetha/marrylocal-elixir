defmodule MarrylocalWeb.Admin.UserController do
  @moduledoc """
  Administrative user lookup, search, and updates.

  Every route using this controller passes through the `:admin_required`
  pipeline, so `conn.assigns.current_user` is always an authenticated admin.
  """

  use MarrylocalWeb, :controller

  alias Marrylocal.Accounts
  alias Marrylocal.Admin.Audit
  alias MarrylocalWeb.PeerVerificationNotifier

  @doc """
  `GET /api/v1/admin/users`

  Optional params:

    * `query` - semicolon-separated terms matched with `ILIKE` against first
      name, last name, email, phone, handle, and shortid.
    * `state` / `city` - location filters; `"All"` and `"All Cities"` are
      ignored.

  Results are capped at 500 and ordered newest first.
  """
  def index(conn, params) do
    users = Accounts.admin_search_users(params)

    json(conn, %{
      status: "success",
      data: %{
        users: Enum.map(users, &serialize/1),
        count: length(users)
      }
    })
  end

  @doc """
  `GET /api/v1/admin/users/lookup?query=...`

  Exact match on email, phone number, `@handle`, shortid, or id.
  """
  def lookup(conn, %{"query" => query}) do
    case Accounts.admin_lookup_user(query) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{status: "error", error: "User not found"})

      user ->
        json(conn, %{status: "success", data: %{user: serialize(user)}})
    end
  end

  def lookup(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{status: "error", error: "query is required"})
  end

  @doc """
  `PATCH /api/v1/admin/users/:id`

  Accepts the admin fields either at the top level or nested under `"user"`.
  """
  def update(conn, %{"id" => id} = params) do
    attrs =
      case params["user"] do
        %{} = user -> user
        _ -> Map.drop(params, ["id"])
      end

    case Accounts.admin_update_user(id, attrs) do
      {:ok, user} ->
        Audit.record(conn, "admin.user.update", user.id, %{updates: attrs})
        json(conn, %{status: "success", data: %{user: serialize(user)}})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", errors: traverse_errors(changeset)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{status: "error", error: "User not found"})
    end
  end

  def update(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{status: "error", error: "id is required"})
  end

  @doc """
  `POST /api/v1/admin/users/bulk-update`

  Body:

      {"user_ids": [1, 2, 3], "updates": {"email_verified": true}}

  The update runs as one atomic `Repo.update_all/3` statement.
  """
  def bulk_update(conn, %{"user_ids" => user_ids, "updates" => updates})
      when is_list(user_ids) and is_map(updates) do
    case Accounts.admin_bulk_update_users(user_ids, updates) do
      {:ok, count} ->
        Audit.record(conn, "admin.users.bulk_update", nil, %{
          user_ids: user_ids,
          updates: updates
        })

        json(conn, %{status: "success", updated_count: count})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", errors: traverse_errors(changeset)})

      {:error, :no_updates} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", error: "No recognised update fields supplied"})
    end
  end

  def bulk_update(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{status: "error", error: "user_ids (list) and updates (object) are required"})
  end

  @peer_grant_default_limit 10
  @peer_grant_max_limit 25
  @peer_grant_default_credits 5
  @peer_grant_min_credits 1
  @peer_grant_max_credits 20

  @doc """
  `POST /api/v1/admin/users/grant-peer-verifier`

  Bootstraps the peer-verification chain from the admin console or the MCP
  server.

  Individual mode (grant or top up one member):

      {"identifier": "priya@example.com", "credits": 5, "dry_run": false}

  City seed mode (bootstrap a launch city):

      {"state": "Telangana", "city": "Hyderabad", "limit": 10, "credits": 5}

  `dry_run: true` returns the exact targets without writing. The live path
  marks each target as peer verified, raises the vouch count to at least 3,
  sets the requested credits, and writes an audit record.
  """
  def grant_peer_verifier(conn, params) do
    with {:ok, credits} <- peer_grant_credits(params["credits"]),
         {:ok, limit} <- peer_grant_limit(params["limit"]),
         {:ok, targets, mode} <- Accounts.admin_peer_grant_targets(params, limit) do
      if peer_grant_dry_run?(params["dry_run"]) do
        json(conn, %{
          status: "preview",
          mode: Atom.to_string(mode),
          target_count: length(targets),
          targets: Enum.map(targets, &serialize/1),
          credits_to_set: credits
        })
      else
        apply_peer_grant(conn, targets, mode, credits, params)
      end
    else
      {:error, reason} -> peer_grant_error(conn, reason)
    end
  end

  defp apply_peer_grant(conn, targets, mode, credits, params) do
    ids = Enum.map(targets, & &1.id)

    case Accounts.admin_grant_peer_verifiers(ids, credits) do
      {:ok, updated} ->
        Audit.record(conn, "grant_peer_verifier", peer_grant_target_id(mode, ids), %{
          mode: mode,
          credits: credits,
          target_ids: Enum.map(updated, & &1.id),
          identifier: params["identifier"],
          state: params["state"],
          city: params["city"]
        })

        PeerVerificationNotifier.grants_applied(updated)

        json(conn, %{
          status: "success",
          mode: Atom.to_string(mode),
          target_count: length(updated),
          credits_to_set: credits,
          users: Enum.map(updated, &serialize/1)
        })

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          status: "error",
          error: "Could not grant peer verifier status: #{inspect(reason)}"
        })
    end
  end

  defp peer_grant_target_id(:individual, [id | _]), do: id
  defp peer_grant_target_id(_mode, _ids), do: nil

  defp peer_grant_credits(nil), do: {:ok, @peer_grant_default_credits}
  defp peer_grant_credits(""), do: {:ok, @peer_grant_default_credits}

  defp peer_grant_credits(value) do
    with {:ok, integer} <- peer_grant_integer(value),
         true <- integer >= @peer_grant_min_credits and integer <= @peer_grant_max_credits do
      {:ok, integer}
    else
      _ ->
        {:error,
         {:invalid, "credits",
          "credits must be an integer between #{@peer_grant_min_credits} and #{@peer_grant_max_credits}."}}
    end
  end

  defp peer_grant_limit(nil), do: {:ok, @peer_grant_default_limit}
  defp peer_grant_limit(""), do: {:ok, @peer_grant_default_limit}

  defp peer_grant_limit(value) do
    with {:ok, integer} <- peer_grant_integer(value),
         true <- integer >= 1 and integer <= @peer_grant_max_limit do
      {:ok, integer}
    else
      _ ->
        {:error,
         {:invalid, "limit", "limit must be an integer between 1 and #{@peer_grant_max_limit}."}}
    end
  end

  defp peer_grant_integer(value) when is_integer(value), do: {:ok, value}

  defp peer_grant_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> {:ok, integer}
      _ -> :error
    end
  end

  defp peer_grant_integer(_value), do: :error

  defp peer_grant_dry_run?(true), do: true
  defp peer_grant_dry_run?(1), do: true

  defp peer_grant_dry_run?(value) when is_binary(value) do
    String.downcase(String.trim(value)) in ["true", "1"]
  end

  defp peer_grant_dry_run?(_value), do: false

  defp peer_grant_error(conn, {:invalid, field, message}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{status: "error", error: message, errors: %{field => [message]}})
  end

  defp peer_grant_error(conn, :missing_target) do
    conn
    |> put_status(:bad_request)
    |> json(%{status: "error", error: "Provide identifier, or both state and city."})
  end

  defp peer_grant_error(conn, :missing_state) do
    conn
    |> put_status(:bad_request)
    |> json(%{status: "error", error: "state is required when seeding a city."})
  end

  defp peer_grant_error(conn, :not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{status: "error", error: "No member matched this identifier."})
  end

  defp peer_grant_error(conn, :inactive_target) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{status: "error", error: "The matched member is not active."})
  end

  defp peer_grant_error(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      status: "error",
      error: "Could not resolve peer verifier targets: #{inspect(reason)}"
    })
  end

  # The admin UI historically used the long-form spellings. Expose both the
  # schema names and those aliases so older clients keep working.
  defp serialize(user) do
    %{
      id: user.id,
      shortid: user.shortid,
      user_handle: user.user_handle,
      first_name: user.first_name,
      last_name: user.last_name,
      email: user.email,
      phone_number: user.phone_number,
      age: user.age,
      gender: user.gender,
      state: user.state,
      city: user.city,
      role: user.role,
      user_state: user.user_state,
      confirmed_at: user.confirmed_at,
      email_verified: user.email_verified,
      aadhar_verified: user.aadhar_verified,
      aadhaar_verified: user.aadhar_verified,
      passport_verified: user.passport_verified,
      license_verified: user.license_verified,
      terms_accepted: user.terms_accepted,
      peer_verified: user.peer_verified,
      peer_vouches_received: user.peer_vouches_received,
      vouch_credits_remaining: user.vouch_credits_remaining,
      is_peer_verifier: user.is_peer_verifier,
      is_available_to_vouch: user.is_available_to_vouch,
      seed_verifier_status: user.seed_verifier_status,
      verified_at: user.verified_at,
      onetime_fees_paid: user.onetime_fees_paid,
      one_time_fees_paid: user.onetime_fees_paid,
      onetime_fees_required: user.onetime_fees_required,
      one_time_fees_required: user.onetime_fees_required,
      accepted_one_time_fees_amount: user.accepted_one_time_fees_amount,
      max_search_distance: user.max_search_distance,
      is_beta_tester: user.is_beta_tester,
      latitude: user.latitude,
      longitude: user.longitude,
      inserted_at: user.inserted_at,
      updated_at: user.updated_at
    }
  end

  defp traverse_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, &translate_error/1)
  end

  defp translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(MarrylocalWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(MarrylocalWeb.Gettext, "errors", msg, opts)
    end
  end
end

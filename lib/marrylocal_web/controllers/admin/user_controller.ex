defmodule MarrylocalWeb.Admin.UserController do
  @moduledoc """
  Administrative user lookup, search, and updates.

  Every route using this controller passes through the `:admin_required`
  pipeline, so `conn.assigns.current_user` is always an authenticated admin.
  """

  use MarrylocalWeb, :controller

  alias Marrylocal.Accounts
  alias Marrylocal.Admin.Audit

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

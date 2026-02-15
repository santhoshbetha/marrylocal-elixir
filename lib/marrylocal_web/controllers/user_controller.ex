defmodule MarrylocalWeb.UserController do
  use MarrylocalWeb, :controller
  import Ecto.Query
  alias Marrylocal.Accounts
  alias Marrylocal.Repo
  alias Marrylocal.Accounts.User

  # GET /api/me
  def show(conn, _params) do
    user = conn.assigns.current_user
    render(conn, :show, user: user)
  end

  # PUT /api/me
  def update(conn, %{"user" => user_params}) do
    user = conn.assigns.current_user

    case Accounts.update_user_profile(user, user_params) do
      {:ok, updated_user} ->
        render(conn, :show, user: updated_user)

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)})
    end
  end

  def show_profile(conn, %{"id" => user_id}) do
    # Ensure the ID is a valid integer before querying
    case Integer.parse(user_id) do
      {id, _} ->
        case Accounts.get_user_by_id(id) do
          {:ok, user} ->
            if user.user_state == :active do
              render(conn, :public_profile, user: user)
            else
              conn |> put_status(:forbidden) |> json(%{error: "Profile inactive"})
            end

          {:error, :not_found} ->
            conn |> put_status(:not_found) |> json(%{error: "User not found"})
        end

      :error ->
        conn |> put_status(:bad_request) |> json(%{error: "Invalid user ID format"})
    end
  end

  # This endpoint receives the shortid of the user to be added. It uses the current_user
  # from the authentication plug.
  def add_to_shortlist(conn, %{"shortid" => target_shortid}) do
    user = conn.assigns.current_user

    # Prevent adding the same ID twice
    if target_shortid in (user.shortlist || []) do
      conn
      |> put_status(:ok)
      |> json(%{message: "User already in your shortlist", shortid: target_shortid})
    else
      case Accounts.add_to_shortlist(user, target_shortid) do
        {:ok, _id} ->
          json(conn, %{message: "User added to shortlist", shortid: target_shortid})

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Target user not found"})
      end
    end
  end

  # It identifies the user from the session and the target from the URL parameter.
  def delete_shortlist(conn, %{"shortid" => target_shortid}) do
    user = conn.assigns.current_user

    # Optional: Check if it actually exists in the list first
    if target_shortid in (user.shortlist || []) do
      Accounts.remove_from_shortlist(user, target_shortid)

      conn
      |> put_status(:ok)
      |> json(%{message: "Removed from shortlist", shortid: target_shortid})
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "User was not in your shortlist"})
    end
  end

  def index_shortlist(conn, params) do
    user = conn.assigns.current_user

    # Ensure the list isn't nil
    shortid_list = user.shortlist || []

    users = Accounts.list_shortlisted_users(shortid_list, params)

    # Use your existing UserJSON to format the output
    render(conn, :index, users: users)
  end

  #searching by email/phone is sensitive, you should protect this route.
  # In this example, we'll return the profile if found
  def find_by_contact(conn, %{"q" => identifier}) do
    case Accounts.get_user_by_contact(identifier) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "No user found with that contact info"})

      user ->
        # Returns the public profile data we defined earlier
        render(conn, :show, user: user)
    end
  end

  def city_count(conn, _params) do
    user = conn.assigns.current_user

    count = Accounts.get_city_usercount(user)

    json(conn, %{
      city: user.city,
      target_gender: if(user.gender == "Male", do: "Female", else: "Male"),
      count: count
    })
  end

  def distance_count(conn, %{"dist" => dist_str}) do
    user = conn.assigns.current_user
    radius_km = String.to_integer(dist_str)

    count = Accounts.get_usercount_by_distance(user, radius_km)

    json(conn, %{
      radius_km: radius_km,
      count: count
    })
  end

  def stats_by_date(conn, %{"date" => date_str}) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        count = Accounts.get_usercount_by_date(date)
        json(conn, %{date: date, count: count})

      {:error, _} ->
        conn |> put_status(400) |> json(%{error: "Invalid date format. Use YYYY-MM-DD"})
    end
  end

  # Default action for "Today"
  def today_count(conn, _params) do
    count = Accounts.get_usercount_by_date()
    json(conn, %{date: Date.utc_today(), count: count})
  end

  def add_referee(conn, %{"referral_code" => code, "new_email" => email}) do
    case Accounts.append_to_referee_emails(code, email) do
      {:ok, _} ->
        json(conn, %{
          message: "Referrer tracked successfully",
          added: email,
          to_code: code
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Invalid referral code"})
    end
  end

  def delete_self(conn, _params) do
    user = conn.assigns.current_user

    case Accounts.delete_user_account(user) do
      {:ok, _result} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Account deleted successfully. Your photos have been purged."})

      {:error, _step, _failed_value, _changes_so_far} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Could not process account deletion"})
    end
  end

  def deactivate_self(conn, _params) do
    user = conn.assigns.current_user

    case Accounts.deactivate_user_account(user) do
      {:ok, _} -> json(conn, %{message: "Account deactivated. You are now hidden from search."})
      {:error, _} -> conn |> put_status(400) |> json(%{error: "Could not deactivate"})
    end
  end


  def update_location(conn, %{"latitude" => lat, "longitude" => lng}) do
    user = conn.assigns.current_user

    case Accounts.update_user_coordinates(user, %{latitude: lat, longitude: lng}) do
      {:ok, _updated_user} ->
        json(conn, %{message: "Location updated successfully"})

      {:error, %Ecto.Changeset{} = changeset} ->
        # Check if the error is specifically about payment
        if Keyword.has_key?(changeset.errors, :latitude) &&
          elem(changeset.errors[:latitude], 0) == "Payment is required to change your location" do
          conn
          |> put_status(:payment_required)
          |> json(%{error: "payment_needed", message: "Please complete payment to change location."})
        else
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)})
        end
    end
  end

  # User shortlists someone, immediately check if it’s a mutual match.
  # If it is, broadcast a real-time alert to both users via Phoenix Channels.
  def shortlist(conn, %{"target_shortid" => target_id}) do
    user = conn.assigns.current_user

    # 1. Atomic update to push the shortid
    from(u in User, where: u.id == ^user.id)
    |> Repo.update_all(push: [shortlist: target_id])

    # 2. Check for mutual match
    target_user = Accounts.get_user_by_shortid(target_id)

    case Accounts.check_mutual_match(user, target_user) do
      {:ok, :mutual_match} ->
        # 3. Notify BOTH users in real-time
        broadcast_match(user, target_user)
        json(conn, %{status: "match", message: "It's a mutual match!"})

      _ ->
        json(conn, %{status: "ok", message: "Shortlisted"})
    end
  end

  defp broadcast_match(u1, u2) do
    # Notify User 1
    MarrylocalWeb.Endpoint.broadcast("notifications:#{u1.id}", "mutual_match", %{
      with_name: u2.first_name,
      with_shortid: u2.shortid
    })
    # Notify User 2
    MarrylocalWeb.Endpoint.broadcast("notifications:#{u2.id}", "mutual_match", %{
      with_name: u1.first_name,
      with_shortid: u1.shortid
    })
  end

  defp translate_error({msg, opts}) do
    Gettext.dgettext(MarrylocalWeb.Gettext, "errors", msg, opts)
  end
end

defmodule MarrylocalWeb.SearchController do
  use MarrylocalWeb, :controller
  alias Marrylocal.Accounts.Search

  def index(conn, params) do
    # Get the authenticated user from the conn
    user = conn.assigns.current_user

    if is_nil(user.latitude) or is_nil(user.longitude) do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Please enable location services or set your city to search nearby."})
    else
      # 1. Clean and Cast parameters from the URL
      search_params = %{
        "religion" => params["religion"],
        "community" => params["community"],
        "economic_status" => params["economic_status"],
        # Convert "true"/"false" strings to actual booleans
        "job_status" => parse_bool(params["job_status"]),
        # New param for filtering active users
        "online_only" => parse_bool(params["online_only"]),
        # Use the logged-in user's stored coordinates
        "latitude" => user.latitude,
        "longitude" => user.longitude,
        "age_from" => parse_int(params["age_from"]),
        "age_to" => parse_int(params["age_to"]),
        "current_user_gender" => user.gender,
        "current_user_id" => user.id,
        "distance" => parse_int(params["dist"]),
        # Assuming shortlist is stored as an array of short IDs
        "current_user_shortlist" => user.shortlist || []
      }

      # 2. Run the dynamic query (now returns a Scrivener.Page struct)
      page = Search.list_users(search_params)

      # Optional: Filter out the logged-in user from their own search results
      # 3. Filter out the logged-in user from the 'entries' list inside the page struct
      # We replace the original entries with the filtered list
      filtered_entries = Enum.reject(page.entries, &(&1.id == user.id))
      paginated_users = %{page | entries: filtered_entries}

      # 4. Return JSON using a specialized render call
      render(conn, :index_paginated, page: paginated_users)
    end
  end

  # Helper to handle empty or invalid numeric params from mobile/web
  defp parse_int(nil), do: nil

  defp parse_int(val) do
    case Integer.parse(val) do
      {num, _} -> num
      :error -> nil
    end
  end

  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(_), do: nil
end

defmodule Marrylocal.Accounts.Search do
  import Ecto.Query
  import Scrivener, only: [paginate: 2]
  alias Marrylocal.{Repo, Accounts.User}

  def list_users(filters \\ %{}) do
    query = User
      |> filter_by_religion(filters["religion"])
      |> filter_by_community(filters["community"])
      |> filter_by_economic_status(filters["economic_status"])
      |> filter_by_job_status(filters["job_status"])
      # New: Filter for users active in the last 15 minutes
      |> filter_by_online_status(filters["online_only"])
      # New: Age Range Filter
      |> filter_by_age_range(filters["age_from"], filters["age_to"])
      # NEW: Exclude IDs already in the current user's shortlist array
      |> exclude_shortlisted(filters["current_user_shortlist"])
      # New: Mandatory Opposite Gender Filter
      |> filter_by_opposite_gender(filters["current_user_gender"])
      |> filter_by_distance(filters["latitude"], filters["longitude"], filters["distance"])
      # Sort by closest first
      |> order_by([u], fragment(
          "ST_Distance(ST_SetSRID(ST_MakePoint(u.longitude, u.latitude), 4326)::geography,
                      ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography)",
          ^filters["longitude"], ^filters["latitude"]
        ))
        # Always enforce these global privacy/status rules
      |> where([u], u.user_state == :active)
      |> order_by([u], desc: u.id)            # Secondary sort for pagination stability

    # Use Repo.paginate instead of Repo.all
    Repo.paginate(query, page: filters["page"] || 1, page_size: filters["page_size"] || 20)
  end

   # Filter by Age Range
  defp filter_by_age_range(query, from_age, to_age) do
    query
    |> then(fn q -> if from_age, do: from(u in q, where: u.age >= ^from_age), else: q end)
    |> then(fn q -> if to_age, do: from(u in q, where: u.age <= ^to_age), else: q end)
  end

  # Filter by Opposite Gender
  defp filter_by_opposite_gender(query, "Male"), do: from(u in query, where: u.gender == "Female")
  defp filter_by_opposite_gender(query, "Female"), do: from(u in query, where: u.gender == "Male")
  defp filter_by_opposite_gender(query, _), do: query # Handle other cases if needed

  defp exclude_shortlisted(query, nil), do: query
  defp exclude_shortlisted(query, []), do: query
  defp exclude_shortlisted(query, shortlist_ids) do
    # Filters the 'shortid' column against the array of strings
    from u in query, where: u.shortid not in ^shortlist_ids
  end


  # Filters for Religion & Community (Skip if nil or "All")
  defp filter_by_religion(query, val) when val in [nil, "All", ""], do: query
  defp filter_by_religion(query, religion) do
    from u in query, where: u.religion == ^religion
  end

  defp filter_by_community(query, val) when val in [nil, "All", ""], do: query
  defp filter_by_community(query, community) do
    from u in query, where: u.community == ^community
  end

  # Filter for Economic Status (Enum)
  defp filter_by_economic_status(query, val) when val in [nil, "All", ""], do: query
  defp filter_by_economic_status(query, status) do
    from u in query, where: u.economic_status == ^status
  end

  # Filter for Job Status (Boolean)
  defp filter_by_job_status(query, nil), do: query
  defp filter_by_job_status(query, status) when is_boolean(status) do
    from u in query, where: u.job_status == ^status
  end
  defp filter_by_job_status(query, _), do: query

  # PostGIS Distance Filter
  defp filter_by_distance(query, lat, lng, radius_km) when is_number(lat) and is_number(lng) do
    # Convert km to meters for the PostGIS ST_DWithin function
    radius_m = (radius_km || 100) * 1000

    from u in query,
      where: fragment(
        "ST_DWithin(ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography,
                  ST_SetSRID(ST_MakePoint(u.longitude, u.latitude), 4326)::geography, ?)",
        ^lng, ^lat, ^radius_m
      )
  end
  defp filter_by_distance(query, _, _, _), do: query


  defp filter_by_online_status(query, true) do
    # Calculate 15 minutes ago
    fifteen_mins_ago = DateTime.utc_now() |> DateTime.add(-15, :minute)

    from u in query, where: u.time_of_login > ^fifteen_mins_ago
  end
  defp filter_by_online_status(query, _), do: query
end

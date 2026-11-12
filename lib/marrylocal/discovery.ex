defmodule Marrylocal.Discovery do
  @moduledoc """
  Locale-first profile discovery.

  Every candidate must be:

    * the opposite gender of the viewer,
    * active and non-deleted,
    * inside the viewer's PostGIS locale radius,
    * not already liked, disliked, shortlisted, or matched by the viewer.

  Lifestyle filters (religion, community/caste, language, education, economic
  status, job status, age) are applied on top. Ordering defaults to real
  geodesic distance and can be switched to age or last-active by the client.
  """

  import Ecto.Query, warn: false
  import Geo.PostGIS

  alias Marrylocal.Accounts.User
  alias Marrylocal.Features
  alias Marrylocal.Geo
  alias Marrylocal.Relationships
  alias Marrylocal.Repo

  @default_per_page 15
  @max_per_page 30

  @education_levels %{
    "High School" => :"High School",
    "Plus 2 level" => :"Plus 2 level",
    "Bachelors level" => :"Bachelors level",
    "Masters level" => :"Masters level"
  }

  @economic_statuses %{
    "Below Middleclass" => :"Below Middleclass",
    "Middleclass" => :Middleclass,
    "Above Middleclass" => :"Above Middleclass"
  }

  @doc """
  Returns `{:ok, %{profiles: [...], pagination: ...}}` or an error atom.

  Radius mode is strictly clamped to 5..300 km. `search_mode=full_city`
  bypasses PostGIS entirely and matches the viewer's exact city instead.
  """
  def discover(viewer, params \\ %{})

  def discover(%User{} = viewer, params) when is_map(params) do
    with opposite when is_binary(opposite) <- opposite_gender(viewer.gender) do
      page = params |> fetch_int("page", 1) |> max(1)
      per_page = params |> fetch_int("per_page", @default_per_page) |> clamp(1, @max_per_page)

      base =
        User
        |> where(
          [u],
          u.id != ^viewer.id and u.user_state == :active and u.gender == ^opposite
        )
        |> Relationships.exclude_acted_on(viewer.id)
        |> Relationships.exclude_hidden(viewer.id)
        |> apply_filters(params, viewer)

      case normalize_string(Map.get(params, "search_mode")) do
        "full_city" -> discover_full_city(viewer, params, base, page, per_page)
        _ -> discover_radius(viewer, params, base, page, per_page)
      end
    else
      nil -> {:error, :unsupported_gender}
    end
  end

  def discover(_viewer, _params), do: {:error, :location_required}

  defp discover_radius(viewer, params, base, page, per_page) do
    case Geo.point_for(viewer) do
      {:ok, origin} ->
        radius_km = radius_for(viewer, params)

        scoped = Geo.within_radius(base, origin, radius_km)
        total = Repo.aggregate(scoped, :count, :id)

        rows =
          scoped
          |> order_discovery(origin, params)
          |> limit(^per_page)
          |> offset(^((page - 1) * per_page))
          |> select([u], %{
            user: u,
            distance_meters: st_distance_in_meters(u.location, ^origin)
          })
          |> Repo.all()

        profiles =
          Enum.map(rows, fn %{user: user, distance_meters: distance_meters} ->
            MarrylocalWeb.UserJSON.public_profile(user)
            |> MarrylocalWeb.UserJSON.with_distance(distance_meters / 1_000)
          end)

        locale = %{
          search_mode: "radius",
          radius_km: radius_km,
          city: viewer.city,
          latitude: elem(origin.coordinates, 1),
          longitude: elem(origin.coordinates, 0)
        }

        {:ok, discovery_result(profiles, page, per_page, total, locale, viewer)}

      :error ->
        {:error, :location_required}
    end
  end

  defp discover_full_city(viewer, params, base, page, per_page) do
    case normalize_string(viewer.city) do
      nil ->
        {:error, :location_required}

      city ->
        scoped =
          from(u in base,
            where: fragment("lower(?) = lower(?)", u.city, ^city)
          )

        total = Repo.aggregate(scoped, :count, :id)

        {profiles, ordering_origin} =
          case Geo.point_for(viewer) do
            {:ok, origin} ->
              rows =
                scoped
                |> order_discovery(origin, params)
                |> limit(^per_page)
                |> offset(^((page - 1) * per_page))
                |> select([u], %{user: u})
                |> select_merge([u], %{
                  distance_meters: st_distance_in_meters(u.location, ^origin)
                })
                |> Repo.all()

              profiles =
                Enum.map(rows, fn %{user: user, distance_meters: distance_meters} ->
                  MarrylocalWeb.UserJSON.public_profile(user)
                  |> with_optional_distance(distance_meters)
                end)

              {profiles, origin}

            :error ->
              rows =
                scoped
                |> order_discovery(nil, params)
                |> limit(^per_page)
                |> offset(^((page - 1) * per_page))
                |> Repo.all()

              {Enum.map(rows, &with_optional_distance(&1, nil)), nil}
          end

        locale = %{
          search_mode: "full_city",
          radius_km: nil,
          city: city,
          latitude: ordering_origin && elem(ordering_origin.coordinates, 1),
          longitude: ordering_origin && elem(ordering_origin.coordinates, 0)
        }

        {:ok, discovery_result(profiles, page, per_page, total, locale, viewer)}
    end
  end

  defp with_optional_distance(profile, meters) when is_number(meters) do
    MarrylocalWeb.UserJSON.with_distance(profile, meters / 1_000)
  end

  defp with_optional_distance(profile, _meters) do
    MarrylocalWeb.UserJSON.with_distance(profile, nil)
  end

  defp discovery_result(profiles, page, per_page, total, locale, viewer) do
    pages = total_pages(total, per_page)
    has_more = page < pages

    %{
      profiles: profiles,
      pagination: %{
        page: page,
        per_page: per_page,
        total: total,
        total_pages: pages,
        has_next_page: has_more,
        has_more: has_more,
        next_cursor: if(has_more, do: page + 1, else: nil)
      },
      locale: locale,
      search_mode: locale.search_mode,
      has_more: has_more,
      next_cursor: if(has_more, do: page + 1, else: nil),
      features: %{
        community_search_enabled: Features.community_search_enabled?(viewer)
      }
    }
  end

  @doc """
  Direct lookup by email, phone, or handle with per-user privacy gates.

  Consent flags are checked on the target row, and the target's 200 km radius
  preference is enforced with PostGIS. Every failure returns `nil` so the
  controller can emit one indistinguishable 404 response.
  """
  def lookup_profile(%User{} = viewer, query) when is_binary(query) do
    with {:ok, vector, value} <- lookup_vector(String.trim(query)) do
      User
      |> where([u], u.user_state == :active)
      |> Relationships.exclude_hidden(viewer.id)
      |> apply_lookup_vector(vector, value)
      |> apply_lookup_distance(Geo.point_for(viewer))
      |> Repo.one()
    else
      _ -> nil
    end
  end

  def lookup_profile(_viewer, _query), do: nil

  defp lookup_vector(query) do
    cond do
      Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, query) ->
        {:ok, :email, String.downcase(query)}

      phone = phone_lookup_value(query) ->
        {:ok, :phone, phone}

      true ->
        handle = query |> String.trim_leading("@") |> String.trim() |> String.downcase()

        if handle == "", do: :error, else: {:ok, :handle, handle}
    end
  end

  defp phone_lookup_value(query) do
    if Regex.match?(~r/^[\d\s()+-]+$/, query) do
      digits = Regex.replace(~r/\D/, query, "")

      if String.length(digits) == 10, do: digits
    end
  end

  defp apply_lookup_vector(query, :email, email) do
    from(u in query,
      where: u.allow_email_search == true and fragment("lower(?) = ?", u.email, ^email)
    )
  end

  defp apply_lookup_vector(query, :phone, digits) do
    from(u in query,
      where:
        u.allow_phone_search == true and
          fragment(
            "right(regexp_replace(?, '\\D', '', 'g'), 10) = ?",
            u.phone_number,
            ^digits
          )
    )
  end

  defp apply_lookup_vector(query, :handle, handle) do
    from(u in query,
      where: u.allow_handle_search == true and fragment("lower(?) = ?", u.user_handle, ^handle)
    )
  end

  defp apply_lookup_distance(query, {:ok, origin}) do
    from(u in query,
      where:
        u.restrict_lookup_to_200km == false or
          st_dwithin_in_meters(u.location, ^origin, 200_000)
    )
  end

  # Without a valid viewer point, only targets that opted out of the radius
  # restriction can be resolved.
  defp apply_lookup_distance(query, :error) do
    from(u in query, where: u.restrict_lookup_to_200km == false)
  end

  defp order_discovery(query, origin, params) do
    case normalize_string(Map.get(params, "sort_by")) do
      "age" -> order_by(query, [u], asc: u.age, asc: u.id)
      "last_active" -> order_by(query, [u], desc: u.last_active_at, desc: u.id)
      _ when is_nil(origin) -> order_by(query, [u], desc: u.last_active_at, desc: u.id)
      _ -> Geo.order_by_distance(query, origin)
    end
  end

  defp apply_filters(query, params, viewer) do
    query
    |> filter_eq("religion", params, :religion)
    |> filter_community(params, viewer)
    |> filter_eq("caste", params, :caste)
    |> filter_eq("language", params, :language)
    |> filter_enum("education_level", params, :education_level, @education_levels)
    |> filter_enum("economic_status", params, :economic_status, @economic_statuses)
    |> filter_bool("job_status", params, :job_status)
    |> filter_age(params)
    |> filter_online(params)
  end

  defp filter_community(query, params, viewer) do
    if Features.community_search_enabled?(viewer) do
      filter_eq(query, "community", params, :community)
    else
      query
    end
  end

  defp filter_eq(query, param_key, params, field) do
    case normalize_string(Map.get(params, param_key)) do
      nil -> query
      value -> from(u in query, where: field(u, ^field) == ^value)
    end
  end

  defp filter_enum(query, param_key, params, field, allowed) do
    with value when is_binary(value) <- normalize_string(Map.get(params, param_key)),
         {:ok, enum} <- Map.fetch(allowed, value) do
      from(u in query, where: field(u, ^field) == ^enum)
    else
      _ -> query
    end
  end

  defp filter_bool(query, param_key, params, field) do
    case normalize_bool(Map.get(params, param_key)) do
      nil -> query
      value -> from(u in query, where: field(u, ^field) == ^value)
    end
  end

  defp filter_age(query, params) do
    age_from = fetch_int(params, "age_from", nil)
    age_to = fetch_int(params, "age_to", nil)

    query
    |> then(fn q -> if age_from, do: from(u in q, where: u.age >= ^age_from), else: q end)
    |> then(fn q -> if age_to, do: from(u in q, where: u.age <= ^age_to), else: q end)
  end

  defp filter_online(query, params) do
    if normalize_bool(Map.get(params, "online_only")) do
      cutoff = DateTime.utc_now() |> DateTime.add(-15, :minute)
      from(u in query, where: u.time_of_login > ^cutoff)
    else
      query
    end
  end

  defp radius_for(viewer, params) do
    params
    |> Map.get(
      "radius_km",
      Map.get(
        params,
        "max_distance",
        Map.get(params, "radius", Map.get(params, "distance"))
      )
    )
    |> case do
      nil -> viewer.max_search_distance || Geo.default_radius_km()
      value -> value
    end
    |> Geo.normalize_radius()
  end

  # The discovery matrix is strictly opposite-gender. Unknown/unspecified
  # genders get a clear 422 instead of an unrestricted feed.
  defp opposite_gender(gender) when is_binary(gender) do
    case String.downcase(String.trim(gender)) do
      "male" -> "Female"
      "female" -> "Male"
      _ -> nil
    end
  end

  defp opposite_gender(_gender), do: nil

  defp fetch_int(params, key, default) do
    case Map.get(params, key) do
      nil ->
        default

      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      "All" -> nil
      "all" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp normalize_bool(true), do: true
  defp normalize_bool(false), do: false
  defp normalize_bool("true"), do: true
  defp normalize_bool("false"), do: false
  defp normalize_bool(_value), do: nil

  defp clamp(value, min_value, max_value), do: value |> max(min_value) |> min(max_value)

  defp total_pages(0, _per_page), do: 0
  defp total_pages(total, per_page), do: div(total + per_page - 1, per_page)
end

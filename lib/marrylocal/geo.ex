defmodule Marrylocal.Geo do
  @moduledoc """
  PostGIS-backed proximity helpers.

  Coordinates are always stored as `geography(Point, 4326)`. PostGIS therefore
  performs geodesic (great-circle) maths in metres, which is exactly what the
  MarryLocal locale model needs for Indian cities. `Geo.PostGIS` macros are used
  instead of raw SQL so the queries stay composable and type-checked.

  Callers never send WKB or SRID values. They send latitude and longitude, and
  this module builds the `Geo.Point` in the correct `{longitude, latitude}`
  order.
  """

  import Ecto.Query, warn: false
  import Geo.PostGIS

  alias Marrylocal.Accounts.User

  @earth_radius_km 6_371.0088
  @default_radius_km 100
  @max_radius_km 300
  @min_radius_km 5
  @coordinate_fuzz_degrees 0.045

  @doc """
  Applies the MeetCutes-style 5 km privacy jitter before persistence.

  Raw GPS coordinates are never stored. The resulting point is still useful for
  radius discovery while the original street location cannot be reconstructed.
  """
  def fuzz_coordinates(latitude, longitude)
      when is_number(latitude) and is_number(longitude) do
    offset_lat = (:rand.uniform() - 0.5) * @coordinate_fuzz_degrees
    offset_lng = (:rand.uniform() - 0.5) * @coordinate_fuzz_degrees

    {latitude + offset_lat, longitude + offset_lng}
  end

  def fuzz_coordinates(latitude, longitude), do: {latitude, longitude}

  @doc "Builds a WGS84 point from a latitude/longitude pair."
  def point(latitude, longitude)
      when is_number(latitude) and is_number(longitude) and
             latitude >= -90 and latitude <= 90 and longitude >= -180 and longitude <= 180 do
    %Geo.Point{
      coordinates: {longitude * 1.0, latitude * 1.0},
      srid: 4326
    }
  end

  def point(_latitude, _longitude), do: nil

  @doc "Extracts the stored point for a user, falling back to legacy floats."
  def point_for(%User{location: %Geo.Point{} = point}), do: {:ok, point}

  def point_for(%User{latitude: latitude, longitude: longitude})
      when is_number(latitude) and is_number(longitude) do
    case point(latitude, longitude) do
      nil -> :error
      point -> {:ok, point}
    end
  end

  def point_for(_user), do: :error

  @doc "Constrains a `User` query to a geodesic radius around an origin point."
  def within_radius(query, %Geo.Point{} = origin, radius_km \\ @default_radius_km) do
    radius_m = radius_km |> normalize_radius() |> Kernel.*(1_000.0)

    from(u in query,
      where: st_dwithin_in_meters(u.location, ^origin, ^radius_m)
    )
  end

  @doc "Orders a `User` query closest-first and selects the distance in metres."
  def order_by_distance(query, %Geo.Point{} = origin) do
    from(u in query,
      order_by: [asc: st_distance_in_meters(u.location, ^origin), asc: u.id]
    )
  end

  @doc "Selects the distance in metres for the given origin."
  def distance_meters(query, %Geo.Point{} = origin) do
    from(u in query, select: st_distance_in_meters(u.location, ^origin))
  end

  @doc """
  Clamps a caller-supplied radius to a sane product limit.

  Discovery defaults to 100 km and can never ask PostGIS to scan more than
  500 km, which keeps the GIST index useful even under malicious input.
  """
  def normalize_radius(radius) when is_integer(radius) or is_float(radius) do
    radius
    |> max(@min_radius_km)
    |> min(@max_radius_km)
  end

  def normalize_radius(radius) when is_binary(radius) do
    case Float.parse(String.trim(radius)) do
      {parsed, ""} -> normalize_radius(parsed)
      _ -> @default_radius_km
    end
  end

  def normalize_radius(_radius), do: @default_radius_km

  def default_radius_km, do: @default_radius_km
  def max_radius_km, do: @max_radius_km

  @doc """
  Pure Elixir great-circle fallback.

  Useful for tests and for serializers that already have both points in memory.
  Production filtering still happens in PostGIS so the database index is used.
  """
  def haversine_km(%Geo.Point{} = a, %Geo.Point{} = b) do
    {lon_a, lat_a} = a.coordinates
    {lon_b, lat_b} = b.coordinates
    haversine_km(lat_a, lon_a, lat_b, lon_b)
  end

  def haversine_km(lat1, lon1, lat2, lon2) do
    dlat = degrees_to_radians(lat2 - lat1)
    dlon = degrees_to_radians(lon2 - lon1)

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(degrees_to_radians(lat1)) * :math.cos(degrees_to_radians(lat2)) *
          :math.sin(dlon / 2) * :math.sin(dlon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))

    @earth_radius_km * c
  end

  defp degrees_to_radians(degrees), do: degrees * :math.pi() / 180
end

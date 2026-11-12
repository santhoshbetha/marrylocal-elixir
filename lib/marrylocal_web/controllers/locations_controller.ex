defmodule MarrylocalWeb.LocationsController do
  @moduledoc """
  Public Indian city autocomplete for onboarding.

  MarryLocal is locale-first and has no venue/event layer, so this endpoint is
  intentionally a small curated city index with coordinates. It is public
  because it is used before the registration token exists; it exposes no user
  data.
  """

  use MarrylocalWeb, :controller

  @cities [
    %{name: "Bengaluru", state: "Karnataka", latitude: 12.9716, longitude: 77.5946},
    %{name: "Mysuru", state: "Karnataka", latitude: 12.2958, longitude: 76.6394},
    %{name: "Mangaluru", state: "Karnataka", latitude: 12.9141, longitude: 74.856},
    %{name: "Hubballi", state: "Karnataka", latitude: 15.3647, longitude: 75.124},
    %{name: "Mumbai", state: "Maharashtra", latitude: 19.076, longitude: 72.8777},
    %{name: "Pune", state: "Maharashtra", latitude: 18.5204, longitude: 73.8567},
    %{name: "Nagpur", state: "Maharashtra", latitude: 21.1458, longitude: 79.0882},
    %{name: "Delhi", state: "Delhi", latitude: 28.6139, longitude: 77.209},
    %{name: "Gurugram", state: "Haryana", latitude: 28.4595, longitude: 77.0266},
    %{name: "Noida", state: "Uttar Pradesh", latitude: 28.5355, longitude: 77.391},
    %{name: "Chennai", state: "Tamil Nadu", latitude: 13.0827, longitude: 80.2707},
    %{name: "Coimbatore", state: "Tamil Nadu", latitude: 11.0168, longitude: 76.9558},
    %{name: "Madurai", state: "Tamil Nadu", latitude: 9.9252, longitude: 78.1198},
    %{name: "Hyderabad", state: "Telangana", latitude: 17.385, longitude: 78.4867},
    %{name: "Warangal", state: "Telangana", latitude: 17.9689, longitude: 79.5941},
    %{name: "Kolkata", state: "West Bengal", latitude: 22.5726, longitude: 88.3639},
    %{name: "Ahmedabad", state: "Gujarat", latitude: 23.0225, longitude: 72.5714},
    %{name: "Surat", state: "Gujarat", latitude: 21.1702, longitude: 72.8311},
    %{name: "Kochi", state: "Kerala", latitude: 9.9312, longitude: 76.2673},
    %{name: "Thiruvananthapuram", state: "Kerala", latitude: 8.5241, longitude: 76.9366},
    %{name: "Jaipur", state: "Rajasthan", latitude: 26.9124, longitude: 75.7873},
    %{name: "Lucknow", state: "Uttar Pradesh", latitude: 26.8467, longitude: 80.9462},
    %{name: "Indore", state: "Madhya Pradesh", latitude: 22.7196, longitude: 75.8577},
    %{name: "Bhopal", state: "Madhya Pradesh", latitude: 23.2599, longitude: 77.4126},
    %{name: "Chandigarh", state: "Chandigarh", latitude: 30.7333, longitude: 76.7794},
    %{name: "Amritsar", state: "Punjab", latitude: 31.634, longitude: 74.8723},
    %{name: "Guwahati", state: "Assam", latitude: 26.1445, longitude: 91.7362},
    %{name: "Bhubaneswar", state: "Odisha", latitude: 20.2961, longitude: 85.8245},
    %{name: "Patna", state: "Bihar", latitude: 25.5941, longitude: 85.1376},
    %{name: "Raipur", state: "Chhattisgarh", latitude: 21.2514, longitude: 81.6296}
  ]

  @doc "GET /api/v1/locations/autocomplete?q=beng"
  def autocomplete(conn, params) do
    query = params["q"] || params["query"] || ""

    locations =
      @cities
      |> Enum.filter(fn city ->
        query == "" or String.contains?(String.downcase(city.name), String.downcase(query))
      end)
      |> Enum.take(10)

    conn
    |> put_status(:ok)
    |> json(%{status: "success", data: %{locations: locations}})
  end
end

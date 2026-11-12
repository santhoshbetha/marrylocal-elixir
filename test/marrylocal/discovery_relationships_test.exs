defmodule Marrylocal.DiscoveryRelationshipsTest do
  use Marrylocal.DataCase, async: true

  import Ecto.Query

  alias Marrylocal.Accounts.User
  alias Marrylocal.Discovery
  alias Marrylocal.Geo
  alias Marrylocal.Notifications.Notification
  alias Marrylocal.Relationships
  alias Marrylocal.Relationships.Relationship
  alias Marrylocal.Repo

  defp profile_fixture(attrs) do
    suffix = System.unique_integer([:positive])

    %User{
      email: "profile#{suffix}@example.com",
      phone_number: "+9199#{rem(suffix, 100_000_000)}",
      first_name: attrs[:first_name] || "Profile",
      last_name: "Test",
      user_handle: "profile#{suffix}",
      shortid: "p#{suffix}",
      referral_code:
        "ML" <> String.pad_leading(Integer.to_string(rem(suffix, 1_000_000)), 6, "0"),
      gender: attrs[:gender] || "Female",
      date_of_birth: ~D[1995-01-01],
      age: attrs[:age] || 31,
      user_state: :active,
      city: attrs[:city] || "Bengaluru",
      state: attrs[:state] || "Karnataka",
      latitude: attrs[:lat] || 12.9716,
      longitude: attrs[:lng] || 77.5946,
      location: Geo.point(attrs[:lat] || 12.9716, attrs[:lng] || 77.5946),
      last_active_at: attrs[:last_active_at] || DateTime.utc_now() |> DateTime.truncate(:second),
      max_search_distance: 100
    }
    |> Repo.insert!()
  end

  test "mutual likes write symmetric matches, notifications, and are idempotent" do
    asha = profile_fixture(%{first_name: "Asha", gender: "Female"})
    bharat = profile_fixture(%{first_name: "Bharat", gender: "Male"})

    assert {:ok, _like, true, [like_notification]} =
             Relationships.create_relationship_with_status(asha.id, bharat.id, :like)

    assert like_notification.type == :profile_like
    assert like_notification.user_id == bharat.id

    assert {:ok, _reverse, true, match_notifications} =
             Relationships.create_relationship_with_status(bharat.id, asha.id, :like)

    assert Enum.map(match_notifications, & &1.type) == [:mutual_match, :mutual_match]

    assert Enum.sort(Enum.map(match_notifications, & &1.user_id)) ==
             Enum.sort([asha.id, bharat.id])

    assert Repo.aggregate(from(r in Relationship, where: r.kind == :match), :count, :id) == 2

    assert Repo.aggregate(from(n in Notification, where: n.type == :mutual_match), :count, :id) ==
             2

    # Repeating the like must not create a second match or duplicate pushes.
    assert {:ok, _same, false, []} =
             Relationships.create_relationship_with_status(bharat.id, asha.id, :like)

    assert Repo.aggregate(from(r in Relationship, where: r.kind == :match), :count, :id) == 2

    assert Repo.aggregate(from(n in Notification, where: n.type == :mutual_match), :count, :id) ==
             2
  end

  test "discovery is opposite-gender, radius-bound, and excludes acted-on profiles" do
    viewer =
      profile_fixture(%{first_name: "Viewer", gender: "Female", lat: 12.9716, lng: 77.5946})

    nearby = profile_fixture(%{first_name: "Nearby", gender: "Male", lat: 12.9352, lng: 77.6245})
    _far = profile_fixture(%{first_name: "Far", gender: "Male", lat: 19.0760, lng: 72.8777})
    _same_gender = profile_fixture(%{first_name: "Same", gender: "Female"})
    disliked = profile_fixture(%{first_name: "Disliked", gender: "Male"})

    {:ok, _relationship} = Relationships.create_relationship(viewer.id, disliked.id, :dislike)

    assert {:ok, result} = Discovery.discover(viewer, %{"radius_km" => 100})
    names = Enum.map(result.profiles, & &1.first_name)

    assert names == ["Nearby"]
    assert result.pagination.total == 1
    assert hd(result.profiles).distance_km < 10
    assert nearby.id
  end

  test "clamps discovery radius between 5 and 300 km" do
    viewer =
      profile_fixture(%{first_name: "Viewer", gender: "Female", lat: 12.9716, lng: 77.5946})

    _nearby = profile_fixture(%{first_name: "Nearby", gender: "Male"})

    assert {:ok, high} = Discovery.discover(viewer, %{"radius_km" => 999})
    assert high.locale.radius_km == 300

    assert {:ok, low} = Discovery.discover(viewer, %{"radius_km" => 1})
    assert low.locale.radius_km == 5
  end

  test "full-city mode bypasses PostGIS and matches the viewer city exactly" do
    viewer =
      profile_fixture(%{
        first_name: "Viewer",
        gender: "Female",
        city: "Delhi",
        lat: 28.6139,
        lng: 77.2090
      })

    same_city =
      profile_fixture(%{
        first_name: "SameCity",
        gender: "Male",
        city: "Delhi",
        lat: 28.7041,
        lng: 77.1025
      })

    _other_city =
      profile_fixture(%{
        first_name: "OtherCity",
        gender: "Male",
        city: "Mumbai",
        lat: 19.0760,
        lng: 72.8777
      })

    assert {:ok, result} = Discovery.discover(viewer, %{"search_mode" => "full_city"})

    assert result.locale.search_mode == "full_city"
    assert result.locale.radius_km == nil
    assert result.locale.city == "Delhi"
    assert Enum.map(result.profiles, & &1.id) == [same_city.id]
    assert hd(result.profiles).distance_km > 0
    assert result.search_mode == "full_city"
    refute result.has_more
    assert result.next_cursor == nil
  end

  test "full-city mode works without viewer coordinates" do
    viewer =
      profile_fixture(%{
        first_name: "Viewer",
        gender: "Female",
        city: "Delhi",
        lat: 28.6139,
        lng: 77.2090
      })
      |> Ecto.Changeset.change(%{latitude: nil, longitude: nil, location: nil})
      |> Repo.update!()

    same_city =
      profile_fixture(%{
        first_name: "SameCity",
        gender: "Male",
        city: "Delhi",
        lat: 28.7041,
        lng: 77.1025
      })

    assert {:ok, result} = Discovery.discover(viewer, %{"search_mode" => "full_city"})
    assert Enum.map(result.profiles, & &1.id) == [same_city.id]
    assert hd(result.profiles).distance_km == nil
  end

  test "discovery paginates in strict pages and reports has_more" do
    viewer =
      profile_fixture(%{
        first_name: "Viewer",
        gender: "Female",
        city: "Delhi",
        lat: 28.6139,
        lng: 77.2090
      })

    for index <- 1..16 do
      profile_fixture(%{first_name: "Page#{index}", gender: "Male", city: "Delhi"})
    end

    assert {:ok, first} =
             Discovery.discover(viewer, %{"search_mode" => "full_city", "per_page" => 15})

    assert length(first.profiles) == 15
    assert first.pagination.total == 16
    assert first.has_more
    assert first.pagination.has_more
    assert first.next_cursor == 2

    assert {:ok, second} =
             Discovery.discover(viewer, %{
               "search_mode" => "full_city",
               "per_page" => 15,
               "page" => 2
             })

    assert length(second.profiles) == 1
    refute second.has_more
    assert second.next_cursor == nil
  end

  test "sorts discovery by age or last active" do
    viewer =
      profile_fixture(%{first_name: "Viewer", gender: "Female", lat: 12.9716, lng: 77.5946})

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    _older =
      profile_fixture(%{
        first_name: "Older",
        gender: "Male",
        age: 40,
        last_active_at: DateTime.add(now, -7200, :second)
      })

    _younger =
      profile_fixture(%{
        first_name: "Younger",
        gender: "Male",
        age: 24,
        last_active_at: now
      })

    assert {:ok, by_age} =
             Discovery.discover(viewer, %{"radius_km" => 100, "sort_by" => "age"})

    assert Enum.map(by_age.profiles, & &1.first_name) == ["Younger", "Older"]

    assert {:ok, by_activity} =
             Discovery.discover(viewer, %{"radius_km" => 100, "sort_by" => "last_active"})

    assert Enum.map(by_activity.profiles, & &1.first_name) == ["Younger", "Older"]
  end

  test "community search feature flag is hidden for public users and bypassed for beta testers" do
    viewer =
      profile_fixture(%{first_name: "Viewer", gender: "Female", lat: 12.9716, lng: 77.5946})

    assert {:ok, public_result} = Discovery.discover(viewer, %{"radius_km" => 100})
    assert public_result.features.community_search_enabled == false

    beta_viewer =
      viewer
      |> Ecto.Changeset.change(is_beta_tester: true)
      |> Repo.update!()

    assert {:ok, beta_result} = Discovery.discover(beta_viewer, %{"radius_km" => 100})
    assert beta_result.features.community_search_enabled == true
  end
end

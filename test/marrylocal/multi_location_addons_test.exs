defmodule Marrylocal.MultiLocationAddonsTest do
  use Marrylocal.DataCase

  import Marrylocal.AccountsFixtures

  alias Marrylocal.{Accounts, Billing, Discovery, Geo, Repo}

  @location_attrs %{
    "state" => "Karnataka",
    "city" => "Bangalore",
    "latitude" => 12.9716,
    "longitude" => 77.5946
  }

  test "activating Location 2 sets a 30-day window and inserts an itemized invoice" do
    user = user_fixture()

    assert {:ok, %{user: updated}} =
             Accounts.activate_subscription(
               user.id,
               %{"location2" => %{"city" => "Bangalore", "state" => "Karnataka"}},
               ~D[2026-11-12]
             )

    assert updated.location_2_city == "Bangalore"
    assert updated.location_2_state == "Karnataka"
    assert updated.location_2_purchased_at
    assert DateTime.compare(updated.location_2_expires_at, DateTime.utc_now()) == :gt

    assert [invoice] = Billing.list_invoices(user.id)
    assert invoice.item_type == "addon_location_2"
    assert invoice.description =~ "Second Location Addon"
    assert Decimal.equal?(invoice.base_amount_inr, Decimal.new("100.00"))
    assert Decimal.equal?(invoice.gst_amount_inr, Decimal.new("18.00"))
    assert Decimal.equal?(invoice.total_amount_inr, Decimal.new("118.00"))
  end

  test "secondary location cooldown is independent from the primary location" do
    user =
      user_fixture(%{city: "Hyderabad", state: "Telangana"})
      |> Ecto.Changeset.change(%{
        location_2_city: "Bangalore",
        location_2_state: "Karnataka",
        location_2_expires_at:
          DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)
      })
      |> Repo.update!()

    assert {:ok, updated} = Accounts.update_location_slot(user, "location_2", @location_attrs)
    assert updated.location_2_last_changed_at
    assert match?(%Elixir.Geo.Point{}, updated.location_2_geom)

    assert {:error, :location_change_locked} =
             Accounts.update_location_slot(updated, "location_2", @location_attrs)

    assert {:ok, primary} =
             Accounts.update_location_slot(updated, "primary", %{
               "state" => "Telangana",
               "city" => "Hyderabad",
               "latitude" => 17.385,
               "longitude" => 78.4867
             })

    assert primary.city == "Hyderabad"
  end

  test "expired secondary locations reject updates and discovery falls back to primary" do
    viewer =
      user_fixture(%{gender: "Female", city: "Hyderabad", state: "Telangana"})
      |> Ecto.Changeset.change(%{
        latitude: 17.385,
        longitude: 78.4867,
        location: Geo.point(17.385, 78.4867),
        location_2_city: "Bangalore",
        location_2_state: "Karnataka",
        location_2_geom: Geo.point(12.9716, 77.5946),
        location_2_expires_at:
          DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)
      })
      |> Repo.update!()

    _same_city = user_fixture(%{gender: "Male", city: "Hyderabad", state: "Telangana"})

    assert {:error, :location_addon_required} =
             Accounts.update_location_slot(viewer, "location_2", @location_attrs)

    assert {:ok, result} =
             Discovery.discover(viewer, %{
               "search_mode" => "full_city",
               "location_slot" => "location_2"
             })

    assert result.locale.location_slot == "primary"
    assert result.locale.city == "Hyderabad"
  end

  test "rejects duplicate city/state pairs across active slots and addon purchases" do
    user =
      user_fixture(%{city: "Hyderabad", state: "Telangana"})
      |> Ecto.Changeset.change(%{
        location_2_city: "Bangalore",
        location_2_state: "Karnataka",
        location_2_expires_at:
          DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)
      })
      |> Repo.update!()

    assert {:error, :duplicate_location} =
             Accounts.update_location_slot(user, "location_2", %{
               "state" => " telangana ",
               "city" => "HYDERABAD",
               "latitude" => 17.385,
               "longitude" => 78.4867
             })

    assert {:error, :duplicate_location} =
             Accounts.update_location_slot(user, "location_3", %{
               "state" => "Karnataka",
               "city" => "Bangalore",
               "latitude" => 12.9716,
               "longitude" => 77.5946
             })

    assert {:error, :duplicate_location} =
             Accounts.validate_addon_locations(user, %{
               "location3" => %{"state" => "Karnataka", "city" => "Bangalore"}
             })

    assert {:error, :duplicate_location} =
             Accounts.activate_subscription(user.id, %{
               "location3" => %{"state" => "Telangana", "city" => "Hyderabad"}
             })
  end

  test "active secondary locations drive full-city discovery" do
    viewer =
      user_fixture(%{gender: "Female", city: "Hyderabad", state: "Telangana"})
      |> Ecto.Changeset.change(%{
        latitude: 17.385,
        longitude: 78.4867,
        location: Geo.point(17.385, 78.4867),
        location_2_city: "Bangalore",
        location_2_state: "Karnataka",
        location_2_geom: Geo.point(12.9716, 77.5946),
        location_2_expires_at:
          DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)
      })
      |> Repo.update!()

    bangalore = user_fixture(%{gender: "Male", city: "Bangalore", state: "Karnataka"})
    _hyderabad = user_fixture(%{gender: "Male", city: "Hyderabad", state: "Telangana"})

    assert {:ok, result} =
             Discovery.discover(viewer, %{
               "search_mode" => "full_city",
               "location_slot" => "location_2"
             })

    assert result.locale.location_slot == "location_2"
    assert result.locale.city == "Bangalore"
    assert Enum.map(result.profiles, & &1.id) == [bangalore.id]
  end
end

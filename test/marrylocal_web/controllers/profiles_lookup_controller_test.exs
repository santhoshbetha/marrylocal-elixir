defmodule MarrylocalWeb.ProfilesLookupControllerTest do
  use MarrylocalWeb.ConnCase, async: true

  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts
  alias Marrylocal.Geo
  alias Marrylocal.Relationships
  alias Marrylocal.Repo

  setup %{conn: conn} do
    viewer = user_fixture()

    target =
      user_fixture(%{
        phone_number:
          "+9198" <>
            String.pad_leading(Integer.to_string(System.unique_integer([:positive])), 8, "0")
      })
      |> Ecto.Changeset.change(%{
        allow_email_search: true,
        allow_phone_search: true,
        allow_handle_search: true,
        restrict_lookup_to_200km: false
      })
      |> Repo.update!()

    token = Accounts.generate_user_session_token(viewer)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")

    %{conn: conn, viewer: viewer, target: target}
  end

  test "looks up an active profile by complete email", %{conn: conn, target: target} do
    conn = get(conn, ~p"/api/v1/profiles/lookup", query: target.email)

    response = json_response(conn, 200)
    assert response["data"]["profile"]["id"] == target.id
    assert response["data"]["profile"]["last_name"] == "U."
  end

  test "reveals the full last name when hide_last_name is disabled", %{
    conn: conn,
    target: target
  } do
    target =
      target
      |> Ecto.Changeset.change(hide_last_name: false)
      |> Repo.update!()

    conn = get(conn, ~p"/api/v1/profiles/lookup", query: target.email)

    response = json_response(conn, 200)
    assert response["data"]["profile"]["last_name"] == "User"
  end

  test "looks up an active profile by normalized 10-digit phone", %{conn: conn, target: target} do
    digits =
      target.phone_number
      |> String.replace(~r/\D/, "")
      |> String.slice(-10, 10)

    conn = get(conn, ~p"/api/v1/profiles/lookup", query: digits)

    response = json_response(conn, 200)
    assert response["data"]["profile"]["id"] == target.id
  end

  test "looks up an active profile by handle with or without @", %{conn: conn, target: target} do
    conn = get(conn, ~p"/api/v1/profiles/lookup", query: "@#{target.user_handle}")

    assert json_response(conn, 200)["data"]["profile"]["id"] == target.id

    conn = get(conn, ~p"/api/v1/profiles/lookup", query: String.upcase(target.user_handle))

    assert json_response(conn, 200)["data"]["profile"]["id"] == target.id
  end

  test "returns 404 for a hidden profile", %{conn: conn, viewer: viewer, target: target} do
    {:ok, _} = Relationships.create_relationship(viewer.id, target.id, :block)

    conn = get(conn, ~p"/api/v1/profiles/lookup", query: target.email)

    assert json_response(conn, 404)["status"] == "error"
  end

  test "returns 404 for a muted profile", %{conn: conn, viewer: viewer, target: target} do
    {:ok, _} = Relationships.create_relationship(viewer.id, target.id, :mute)

    conn = get(conn, ~p"/api/v1/profiles/lookup", query: target.email)

    assert json_response(conn, 404)["status"] == "error"
  end

  test "rejects incomplete lookup values", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/profiles/lookup", query: "123")

    assert json_response(conn, 404)["status"] == "error"
  end

  test "serializes lookup privacy flags on the private profile", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/profiles/me")

    profile = json_response(conn, 200)["data"]["profile"]

    assert profile["restrict_lookup_to_200km"] == true
    refute profile["allow_email_search"]
    refute profile["allow_phone_search"]
    assert profile["allow_handle_search"] == true
  end

  test "requires email search consent", %{conn: conn, target: target} do
    target =
      target
      |> Ecto.Changeset.change(allow_email_search: false)
      |> Repo.update!()

    conn = get(conn, ~p"/api/v1/profiles/lookup", query: target.email)

    assert_lookup_not_found(conn)
  end

  test "requires phone search consent", %{conn: conn, target: target} do
    target =
      target
      |> Ecto.Changeset.change(allow_phone_search: false)
      |> Repo.update!()

    digits =
      target.phone_number
      |> String.replace(~r/\D/, "")
      |> String.slice(-10, 10)

    conn = get(conn, ~p"/api/v1/profiles/lookup", query: digits)

    assert_lookup_not_found(conn)
  end

  test "requires handle search consent", %{conn: conn, target: target} do
    target =
      target
      |> Ecto.Changeset.change(allow_handle_search: false)
      |> Repo.update!()

    conn = get(conn, ~p"/api/v1/profiles/lookup", query: "@#{target.user_handle}")

    assert_lookup_not_found(conn)
  end

  test "allows lookup inside 200 km when the target restricts radius", %{
    conn: conn,
    viewer: viewer,
    target: target
  } do
    _viewer = put_coordinates(viewer, 12.9716, 77.5946)
    target = put_coordinates(target, 12.2958, 76.6394)

    conn = get(conn, ~p"/api/v1/profiles/lookup", query: "@#{target.user_handle}")

    assert json_response(conn, 200)["data"]["profile"]["id"] == target.id
  end

  test "blocks lookup beyond 200 km when the target restricts radius", %{
    conn: conn,
    viewer: viewer,
    target: target
  } do
    _viewer = put_coordinates(viewer, 12.9716, 77.5946)
    target = put_coordinates(target, 28.6139, 77.2090)

    conn = get(conn, ~p"/api/v1/profiles/lookup", query: "@#{target.user_handle}")

    assert_lookup_not_found(conn)
  end

  test "blocks restricted lookup when the viewer has no coordinates", %{
    conn: conn,
    target: target
  } do
    target = put_coordinates(target, 12.2958, 76.6394)

    conn = get(conn, ~p"/api/v1/profiles/lookup", query: "@#{target.user_handle}")

    assert_lookup_not_found(conn)
  end

  test "blocks restricted lookup when the target has no coordinates", %{
    conn: conn,
    viewer: viewer,
    target: target
  } do
    _viewer = put_coordinates(viewer, 12.9716, 77.5946)
    target = Ecto.Changeset.change(target, restrict_lookup_to_200km: true) |> Repo.update!()

    conn = get(conn, ~p"/api/v1/profiles/lookup", query: "@#{target.user_handle}")

    assert_lookup_not_found(conn)
  end

  test "allows any distance when the target disables the radius restriction", %{
    conn: conn,
    viewer: viewer,
    target: target
  } do
    _viewer = put_coordinates(viewer, 12.9716, 77.5946)
    target = put_coordinates(target, 28.6139, 77.2090, false)

    conn = get(conn, ~p"/api/v1/profiles/lookup", query: "@#{target.user_handle}")

    assert json_response(conn, 200)["data"]["profile"]["id"] == target.id
  end

  test "uses the same 404 body for hidden consent and missing profiles", %{
    conn: conn,
    target: target
  } do
    target =
      target
      |> Ecto.Changeset.change(allow_email_search: false)
      |> Repo.update!()

    disabled_conn = get(conn, ~p"/api/v1/profiles/lookup", query: target.email)
    missing_conn = get(conn, ~p"/api/v1/profiles/lookup", query: "nobody@example.com")

    assert json_response(disabled_conn, 404) == json_response(missing_conn, 404)
  end

  defp put_coordinates(user, latitude, longitude, restrict \\ true) do
    user
    |> Ecto.Changeset.change(%{
      latitude: latitude,
      longitude: longitude,
      location: Geo.point(latitude, longitude),
      restrict_lookup_to_200km: restrict
    })
    |> Repo.update!()
  end

  defp assert_lookup_not_found(conn) do
    assert json_response(conn, 404) == %{
             "status" => "error",
             "message" => "No matching profile found."
           }
  end
end

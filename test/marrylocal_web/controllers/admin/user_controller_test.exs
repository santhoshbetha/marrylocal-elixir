defmodule MarrylocalWeb.Admin.UserControllerTest do
  use MarrylocalWeb.ConnCase, async: true

  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts
  alias Marrylocal.Accounts.User
  alias Marrylocal.Repo

  defp admin_conn(conn) do
    admin = user_fixture()
    {:ok, admin} = admin |> Ecto.Changeset.change(role: :admin) |> Repo.update()
    token = Accounts.generate_user_session_token(admin)

    {put_req_header(conn, "authorization", "Bearer #{token}"), admin}
  end

  test "index searches names, email, phone, handle, and shortid", %{conn: conn} do
    {conn, _admin} = admin_conn(conn)

    alpha =
      user_fixture(%{
        first_name: "Alphonse",
        last_name: "Searchable",
        state: "Karnataka",
        city: "Bangalore"
      })

    beta =
      user_fixture(%{
        first_name: "Betamax",
        last_name: "Searchable",
        state: "Karnataka",
        city: "Mysore"
      })

    _gamma = user_fixture(%{first_name: "Gammamax", last_name: "Unrelated"})

    conn = get(conn, ~p"/api/v1/admin/users", %{"query" => "alphonse;betamax"})
    body = json_response(conn, 200)

    ids = body["data"]["users"] |> Enum.map(& &1["id"]) |> Enum.sort()
    assert ids == Enum.sort([alpha.id, beta.id])
    assert body["data"]["count"] == 2

    # Phone and handle fragments also match.
    conn = get(conn, ~p"/api/v1/admin/users", %{"query" => beta.phone_number})
    assert [%{"id" => id}] = json_response(conn, 200)["data"]["users"]
    assert id == beta.id
  end

  test "index filters by state and city and ignores the All sentinels", %{conn: conn} do
    {conn, _admin} = admin_conn(conn)

    bangalore =
      user_fixture(%{state: "Karnataka", city: "Bangalore", first_name: "Blrperson"})

    _mysore = user_fixture(%{state: "Karnataka", city: "Mysore", first_name: "Mysperson"})
    _delhi = user_fixture(%{state: "Delhi", city: "New Delhi", first_name: "Delhiperson"})

    conn = get(conn, ~p"/api/v1/admin/users", %{"state" => "Karnataka", "city" => "Bangalore"})
    assert [%{"id" => id}] = json_response(conn, 200)["data"]["users"]
    assert id == bangalore.id

    conn = get(conn, ~p"/api/v1/admin/users", %{"state" => "All", "city" => "All Cities"})
    assert json_response(conn, 200)["data"]["count"] >= 3
  end

  test "lookup strips @ and returns 404 for unknown values", %{conn: conn} do
    {conn, _admin} = admin_conn(conn)
    target = user_fixture(%{user_handle: "lookupme"})

    conn = get(conn, ~p"/api/v1/admin/users/lookup", %{"query" => "@lookupme"})
    body = json_response(conn, 200)
    assert body["data"]["user"]["id"] == target.id

    conn = get(conn, ~p"/api/v1/admin/users/lookup", %{"query" => "nobody-matches"})
    assert json_response(conn, 404)
  end

  test "update applies aliases and never allows role escalation", %{conn: conn} do
    {conn, _admin} = admin_conn(conn)
    target = user_fixture()

    conn =
      patch(conn, ~p"/api/v1/admin/users/#{target.id}", %{
        "user" => %{
          "email_verified" => true,
          "aadhaar_verified" => true,
          "one_time_fees_paid" => true,
          "max_search_distance" => 250,
          "role" => "admin"
        }
      })

    body = json_response(conn, 200)
    assert body["data"]["user"]["email_verified"] == true
    assert body["data"]["user"]["aadhaar_verified"] == true
    assert body["data"]["user"]["one_time_fees_paid"] == true

    reloaded = Repo.get!(User, target.id)
    assert reloaded.email_verified
    assert reloaded.aadhar_verified
    assert reloaded.onetime_fees_paid
    assert reloaded.max_search_distance == 250
    assert reloaded.role == :user
  end

  test "update rejects invalid values", %{conn: conn} do
    {conn, _admin} = admin_conn(conn)
    target = user_fixture()

    conn =
      patch(conn, ~p"/api/v1/admin/users/#{target.id}", %{"user" => %{"age" => 12}})

    assert json_response(conn, 422)["errors"]["age"]
  end

  test "bulk_update applies one atomic statement to the selected users", %{conn: conn} do
    {conn, _admin} = admin_conn(conn)

    first = user_fixture()
    second = user_fixture()
    untouched = user_fixture()

    conn =
      post(conn, ~p"/api/v1/admin/users/bulk-update", %{
        "user_ids" => [first.id, second.id],
        "updates" => %{"is_beta_tester" => true, "user_state" => "active"}
      })

    assert json_response(conn, 200) == %{"status" => "success", "updated_count" => 2}

    for user <- [first, second] do
      reloaded = Repo.get!(User, user.id)
      assert reloaded.is_beta_tester
      assert reloaded.user_state == :active
    end

    refute Repo.get!(User, untouched.id).is_beta_tester
  end

  test "bulk_update rejects a payload with no recognised fields", %{conn: conn} do
    {conn, _admin} = admin_conn(conn)
    target = user_fixture()

    conn =
      post(conn, ~p"/api/v1/admin/users/bulk-update", %{
        "user_ids" => [target.id],
        "updates" => %{"role" => "admin"}
      })

    assert json_response(conn, 422)
    assert Repo.get!(User, target.id).role == :user
  end

  test "rejects non-admin callers with 403", %{conn: conn} do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user)
    conn = put_req_header(conn, "authorization", "Bearer #{token}")

    assert json_response(get(conn, ~p"/api/v1/admin/users"), 403)
  end
end

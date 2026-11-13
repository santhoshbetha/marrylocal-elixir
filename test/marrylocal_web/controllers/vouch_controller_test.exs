defmodule MarrylocalWeb.VouchControllerTest do
  use MarrylocalWeb.ConnCase, async: false

  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts
  alias Marrylocal.Repo

  setup %{conn: conn} do
    vouchee =
      active_user(%{
        city: "Delhi",
        state: "Delhi",
        first_name: "Vouchee",
        user_handle:
          "vch#{String.pad_leading(Integer.to_string(rem(System.unique_integer([:positive]), 1_000_000)), 6, "0")}"
      })
      |> with_location(28.6139, 77.2090)

    verifier_one =
      active_user(%{
        city: "Delhi",
        state: "Delhi",
        first_name: "Meera",
        last_name: "Sharma",
        user_handle:
          "mvr#{String.pad_leading(Integer.to_string(rem(System.unique_integer([:positive]), 1_000_000)), 6, "0")}",
        allow_phone_search: true
      })
      |> with_location(28.6200, 77.2100)
      |> make_verifier()

    verifier_two =
      active_user(%{
        city: "Delhi",
        state: "Delhi",
        first_name: "Kabir",
        last_name: "Malhotra",
        user_handle:
          "kbr#{String.pad_leading(Integer.to_string(rem(System.unique_integer([:positive]), 1_000_000)), 6, "0")}"
      })
      |> with_location(28.6300, 77.2200)
      |> make_verifier()

    verifier_three =
      active_user(%{
        city: "Delhi",
        state: "Delhi",
        first_name: "Ananya",
        last_name: "Rao",
        user_handle:
          "anr#{String.pad_leading(Integer.to_string(rem(System.unique_integer([:positive]), 1_000_000)), 6, "0")}"
      })
      |> with_location(28.6400, 77.2300)
      |> make_verifier()

    mumbai =
      active_user(%{city: "Mumbai", state: "Maharashtra"})
      |> make_verifier()

    zero_credits =
      active_user(%{city: "Delhi", state: "Delhi"})
      |> Ecto.Changeset.change(peer_verified: true, vouch_credits_remaining: 0)
      |> Repo.update!()

    vouchee_token = Accounts.generate_user_session_token(vouchee)

    {:ok,
     conn: conn,
     vouchee: vouchee,
     vouchee_token: vouchee_token,
     verifiers: [verifier_one, verifier_two, verifier_three],
     mumbai: mumbai,
     zero_credits: zero_credits}
  end

  test "nearest verifiers returns only same-city members with credits", %{
    conn: conn,
    vouchee: vouchee,
    vouchee_token: token,
    verifiers: verifiers,
    mumbai: mumbai,
    zero_credits: zero_credits
  } do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/api/v1/vouch/nearest-verifiers")

    body = json_response(conn, 200)
    returned_ids = Enum.map(body["data"]["verifiers"], & &1["id"])

    assert Enum.sort(returned_ids) == Enum.sort(Enum.map(verifiers, & &1.id))
    refute mumbai.id in returned_ids
    refute zero_credits.id in returned_ids
    refute vouchee.id in returned_ids

    [first | _] = body["data"]["verifiers"]
    assert first["city"] == "Delhi"
    assert is_float(first["distance_km"]) or is_integer(first["distance_km"])
    assert first["vouch_credits_remaining"] == 5
    assert is_binary(first["handle"])
  end

  test "generate token and verify peer endpoint succeed, then duplicate is rejected", %{
    conn: conn,
    vouchee_token: vouchee_token,
    verifiers: [voucher | _]
  } do
    token_conn =
      conn
      |> put_req_header("authorization", "Bearer #{vouchee_token}")
      |> post(~p"/api/v1/vouch/generate-token")

    token_body = json_response(token_conn, 200)
    assert token_body["expires_in"] == 60
    assert is_binary(token_body["secure_token"])

    voucher_token = Accounts.generate_user_session_token(voucher)

    vouch_conn =
      conn
      |> put_req_header("authorization", "Bearer #{voucher_token}")
      |> post(~p"/api/v1/vouch/verify-peer", %{"secure_token" => token_body["secure_token"]})

    vouch_body = json_response(vouch_conn, 200)
    assert vouch_body["current_vouches"] == 1
    refute vouch_body["peer_verified"]
    assert vouch_body["data"]["voucher_credits_remaining"] == 4

    second_token_conn =
      conn
      |> put_req_header("authorization", "Bearer #{vouchee_token}")
      |> post(~p"/api/v1/vouch/generate-token")

    second_token = json_response(second_token_conn, 200)["secure_token"]

    duplicate_conn =
      conn
      |> put_req_header("authorization", "Bearer #{voucher_token}")
      |> post(~p"/api/v1/vouch/verify-peer", %{"secure_token" => second_token})

    assert json_response(duplicate_conn, 422)["code"] == "duplicate_vouch"
  end

  test "expired or consumed tokens are rejected", %{conn: conn, vouchee_token: token} do
    token_conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(~p"/api/v1/vouch/generate-token")

    secure_token = json_response(token_conn, 200)["secure_token"]

    assert {:ok, _user_id} = Marrylocal.Verification.VouchCache.consume_token(secure_token)

    consumed_conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(~p"/api/v1/vouch/verify-peer", %{"secure_token" => secure_token})

    assert json_response(consumed_conn, 400)["code"] == "token_invalid"
  end

  defp active_user(attrs) do
    user_fixture(attrs)
    |> Ecto.Changeset.change(user_state: Map.get(attrs, :user_state, :active))
    |> Repo.update!()
  end

  defp make_verifier(user) do
    user
    |> Ecto.Changeset.change(peer_verified: true, vouch_credits_remaining: 5)
    |> Repo.update!()
  end

  defp with_location(user, latitude, longitude) do
    point = %Geo.Point{coordinates: {longitude, latitude}, srid: 4326}

    user
    |> Ecto.Changeset.change(location: point, latitude: latitude, longitude: longitude)
    |> Repo.update!()
  end
end

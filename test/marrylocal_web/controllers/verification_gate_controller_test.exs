defmodule MarrylocalWeb.VerificationGateControllerTest do
  use MarrylocalWeb.ConnCase, async: true

  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts
  alias Marrylocal.Features
  alias Marrylocal.Repo

  defp token_for(user) do
    Accounts.generate_user_session_token(user)
  end

  test "blocks discovery and lookup for users pending verification", %{conn: _conn} do
    user =
      user_fixture(%{city: "Delhi", gender: "Female"})
      |> Ecto.Changeset.change(force_verification_required: true)
      |> Repo.update!()

    token = token_for(user)

    responses = [
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/api/v1/profiles/discovery"),
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/api/v1/profiles/lookup", query: user.email)
    ]

    for response <- responses do
      body = json_response(response, 403)
      assert body["code"] == "VERIFICATION_REQUIRED"

      assert body["message"] ==
               "Identity verification is required to continue searching in your area."
    end
  end

  test "blocks discovery and lookup when the payment gate is active", %{conn: _conn} do
    user =
      user_fixture(%{city: "Delhi", gender: "Female"})
      |> Ecto.Changeset.change(%{
        onetime_fees_required: true,
        onetime_fees_paid: false
      })
      |> Repo.update!()

    previous = Application.get_env(:marrylocal, :features)

    on_exit(fn ->
      Application.put_env(:marrylocal, :features, previous || [])
    end)

    Features.put_enforce_payment_gate(true)
    token = token_for(user)

    response =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/api/v1/profiles/discovery")

    body = json_response(response, 403)
    assert body["code"] == "PAYMENT_REQUIRED"
    assert body["message"] == "Annual service fee payment is required to continue searching."
  end

  test "admins can toggle the master verification gate at runtime", %{conn: conn} do
    admin =
      user_fixture()
      |> Ecto.Changeset.change(role: :admin)
      |> Repo.update!()

    token = token_for(admin)
    previous = Application.get_env(:marrylocal, :features)
    previous_verification = Application.get_env(:marrylocal, :verification)

    on_exit(fn ->
      Application.put_env(:marrylocal, :features, previous || [])
      Application.put_env(:marrylocal, :verification, previous_verification || [])
    end)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")

    initial = json_response(get(conn, ~p"/api/v1/admin/settings"), 200)
    assert is_boolean(initial["data"]["settings"]["enforce_verification_gate"])
    assert is_boolean(initial["data"]["settings"]["enforce_payment_gate"])
    assert initial["data"]["settings"]["verification_validity_days"] == 730

    updated =
      json_response(
        patch(conn, ~p"/api/v1/admin/settings/gating", %{
          enforce_verification_gate: true,
          enforce_payment_gate: true,
          verification_validity_days: 365
        }),
        200
      )

    assert updated["data"]["settings"]["enforce_verification_gate"] == true
    assert updated["data"]["settings"]["enforce_payment_gate"] == true
    assert updated["data"]["settings"]["verification_validity_days"] == 365

    refreshed = json_response(get(conn, ~p"/api/v1/admin/settings"), 200)
    assert refreshed["data"]["settings"]["enforce_verification_gate"] == true
    assert refreshed["data"]["settings"]["enforce_payment_gate"] == true
    assert refreshed["data"]["settings"]["verification_validity_days"] == 365

    invalid =
      json_response(
        patch(conn, ~p"/api/v1/admin/settings", %{verification_validity_days: 0}),
        422
      )

    assert invalid["status"] == "error"

    disabled =
      json_response(
        patch(conn, ~p"/api/v1/admin/settings", %{
          enforce_verification_gate: false,
          enforce_payment_gate: false
        }),
        200
      )

    assert disabled["data"]["settings"]["enforce_verification_gate"] == false
    assert disabled["data"]["settings"]["enforce_payment_gate"] == false
  end
end

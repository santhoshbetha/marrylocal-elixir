defmodule MarrylocalWeb.Admin.McpAdminApiTest do
  @moduledoc """
  Contract tests for the endpoints consumed by the standalone MCP server.

  These run synchronously because the scoped service-token test mutates
  process-wide environment variables.
  """

  use MarrylocalWeb.ConnCase, async: false
  use Oban.Testing, repo: Marrylocal.Repo

  import Ecto.Query
  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts
  alias Marrylocal.Accounts.IdentityVerification
  alias Marrylocal.Accounts.User
  alias Marrylocal.Admin.AuditLog
  alias Marrylocal.Billing.Invoice
  alias Marrylocal.Features
  alias Marrylocal.Repo

  @mcp_token "mcp-test-token-0123456789-abcdefghijklmnopqrstuvwxyz"

  setup %{conn: conn} do
    previous_token = System.get_env("MCP_ADMIN_TOKEN")
    previous_email = System.get_env("MCP_ADMIN_EMAIL")

    admin = user_fixture()
    {:ok, admin} = admin |> Ecto.Changeset.change(role: :admin) |> Repo.update()

    System.put_env("MCP_ADMIN_TOKEN", @mcp_token)
    System.put_env("MCP_ADMIN_EMAIL", admin.email)

    on_exit(fn ->
      restore_env("MCP_ADMIN_TOKEN", previous_token)
      restore_env("MCP_ADMIN_EMAIL", previous_email)
    end)

    mcp_conn = put_req_header(conn, "authorization", "Bearer #{@mcp_token}")

    {:ok, admin: admin, conn: conn, mcp_conn: mcp_conn}
  end

  describe "scoped MCP service token" do
    test "authenticates admin API reads", %{mcp_conn: conn} do
      body = json_response(get(conn, ~p"/api/v1/admin/settings/gating"), 200)
      assert body["data"]["settings"]["default_annual_fee_inr"] == 500
    end

    test "is rejected outside /api/v1/admin", %{mcp_conn: conn} do
      assert json_response(get(conn, ~p"/api/v1/profiles/me"), 401)
    end

    test "does not authenticate when the configured account is not an admin", %{
      conn: conn,
      admin: admin
    } do
      member = user_fixture()
      System.put_env("MCP_ADMIN_EMAIL", member.email)

      _ = admin
      conn = put_req_header(conn, "authorization", "Bearer #{@mcp_token}")

      assert json_response(get(conn, ~p"/api/v1/admin/settings/gating"), 401)
    end

    test "write actions are audited with source mcp", %{mcp_conn: conn} do
      previous = Features.enforce_verification_gate?()
      on_exit(fn -> Features.put_enforce_verification_gate(previous) end)

      body =
        conn
        |> patch(~p"/api/v1/admin/settings/gating", %{"enforce_verification_gate" => true})
        |> json_response(200)

      assert body["data"]["settings"]["enforce_verification_gate"] == true

      log = Repo.one(from l in AuditLog, order_by: [desc: l.id], limit: 1)
      assert log.source == "mcp"
      assert log.action == "admin.settings.update"
      assert log.admin_id
    end

    test "X-Admin-Client marks a session-authenticated write as mcp", %{conn: conn} do
      admin = user_fixture()
      {:ok, admin} = admin |> Ecto.Changeset.change(role: :admin) |> Repo.update()
      token = Accounts.generate_user_session_token(admin)

      previous = Features.enforce_payment_gate?()
      on_exit(fn -> Features.put_enforce_payment_gate(previous) end)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("x-admin-client", "mcp")
        |> patch(~p"/api/v1/admin/settings/gating", %{"enforce_payment_gate" => false})

      assert json_response(conn, 200)

      log = Repo.one(from l in AuditLog, order_by: [desc: l.id], limit: 1)
      assert log.source == "mcp"
    end
  end

  describe "location search flags" do
    test "filters unverified and paid users", %{mcp_conn: conn} do
      unverified =
        user_fixture(%{state: "Karnataka", city: "Hubballi", first_name: "Unverified"})

      paid =
        user_fixture(%{state: "Karnataka", city: "Hubballi", first_name: "Paid"})

      {:ok, paid} =
        paid
        |> Ecto.Changeset.change(onetime_fees_paid: true, passport_verified: true)
        |> Repo.update()

      unverified_body =
        conn
        |> get(~p"/api/v1/admin/users", %{
          "state" => "Karnataka",
          "city" => "Hubballi",
          "unverified_only" => "true"
        })
        |> json_response(200)

      assert Enum.map(unverified_body["data"]["users"], & &1["id"]) == [unverified.id]

      paid_body =
        conn
        |> get(~p"/api/v1/admin/users", %{
          "state" => "Karnataka",
          "city" => "Hubballi",
          "paid_only" => "true"
        })
        |> json_response(200)

      assert Enum.map(paid_body["data"]["users"], & &1["id"]) == [paid.id]
    end
  end

  describe "invoice search" do
    test "matches invoice number, email, and @handle", %{mcp_conn: conn} do
      user = user_fixture(%{user_handle: "invoicesearch"})
      invoice = insert_invoice(user, "INV-MCP-1001")

      by_number =
        conn
        |> get(~p"/api/v1/admin/invoices", %{"query" => invoice.invoice_number})
        |> json_response(200)

      assert [%{"id" => id, "user" => %{"id" => user_id}}] = by_number["data"]["invoices"]
      assert id == invoice.id
      assert user_id == user.id

      by_email =
        conn
        |> get(~p"/api/v1/admin/invoices", %{"query" => user.email})
        |> json_response(200)

      assert length(by_email["data"]["invoices"]) == 1

      by_handle =
        conn
        |> get(~p"/api/v1/admin/invoices", %{"query" => "@#{user.user_handle}"})
        |> json_response(200)

      assert length(by_handle["data"]["invoices"]) == 1
    end
  end

  describe "verification queue filters" do
    test "returns only submissions older than the requested age", %{mcp_conn: conn} do
      old = insert_verification(user_fixture(), hours_ago: 48)
      _fresh = insert_verification(user_fixture(), hours_ago: 1)

      body =
        conn
        |> get(~p"/api/v1/admin/verifications", %{
          "status" => "pending_admin_review",
          "older_than_hours" => "24"
        })
        |> json_response(200)

      ids = Enum.map(body["data"]["verifications"], & &1["id"])
      assert ids == [old.id]
      assert [%{"duplicate_identity_hash_warning" => false}] = body["data"]["verifications"]
    end

    test "approves a submission and audits the MCP action", %{mcp_conn: conn} do
      verification = insert_verification(user_fixture(), hours_ago: 2)

      body =
        conn
        |> post(~p"/api/v1/admin/verifications/#{verification.id}/approve")
        |> json_response(200)

      assert body["data"]["verification"]["status"] == "verified"

      log = Repo.one(from l in AuditLog, order_by: [desc: l.id], limit: 1)
      assert log.source == "mcp"
      assert log.action == "admin.verification.approve"
      assert log.target_id == verification.id
    end

    test "rejects a submission with a reason", %{mcp_conn: conn} do
      verification = insert_verification(user_fixture(), hours_ago: 2)

      body =
        conn
        |> post(~p"/api/v1/admin/verifications/#{verification.id}/reject", %{
          "reason" => "Document photo is unreadable."
        })
        |> json_response(200)

      assert body["data"]["verification"]["status"] == "rejected"

      log = Repo.one(from l in AuditLog, order_by: [desc: l.id], limit: 1)
      assert log.action == "admin.verification.reject"
      assert log.metadata["reason"] == "Document photo is unreadable."
    end
  end

  describe "dry runs" do
    test "notification broadcast returns a recipient count without enqueueing", %{mcp_conn: conn} do
      _female = user_fixture(%{city: "Kochi", state: "Kerala", gender: "Female"})
      _male = user_fixture(%{city: "Kochi", state: "Kerala", gender: "Male"})

      body =
        conn
        |> post(~p"/api/v1/admin/notifications/broadcast", %{
          "target_type" => "location",
          "state" => "Kerala",
          "city" => "Kochi",
          "gender" => "Female",
          "title" => "Preview",
          "body" => "This must not queue.",
          "dry_run" => true
        })
        |> json_response(200)

      assert body["status"] == "preview"
      assert body["estimated_recipients"] == 1
      refute_enqueued(worker: Marrylocal.Workers.SystemNotificationWorker)
    end

    test "bulk email returns a recipient count without enqueueing", %{mcp_conn: conn} do
      _female = user_fixture(%{city: "Kochi", state: "Kerala", gender: "Female"})

      body =
        conn
        |> post(~p"/api/v1/admin/emails/bulk-send", %{
          "mode" => "location",
          "state" => "Kerala",
          "city" => "Kochi",
          "gender" => "Female",
          "subject" => "Preview",
          "content" => "<p>This must not queue.</p>",
          "dry_run" => true
        })
        |> json_response(200)

      assert body["status"] == "preview"
      assert body["recipient_count"] == 1
      refute_enqueued(worker: Marrylocal.Workers.BulkEmailWorker)
    end
  end

  describe "gating settings" do
    test "updates the annual fee and returns the new value", %{mcp_conn: conn} do
      previous = Application.get_env(:marrylocal, :billing, [])[:default_annual_fee_inr]

      on_exit(fn ->
        billing =
          :marrylocal
          |> Application.get_env(:billing, [])
          |> Keyword.put(:default_annual_fee_inr, previous)

        Application.put_env(:marrylocal, :billing, billing)
      end)

      body =
        conn
        |> patch(~p"/api/v1/admin/settings/gating", %{"default_annual_fee_inr" => 750})
        |> json_response(200)

      assert body["data"]["settings"]["default_annual_fee_inr"] == 750

      read_back =
        conn
        |> get(~p"/api/v1/admin/settings/gating")
        |> json_response(200)

      assert read_back["data"]["settings"]["default_annual_fee_inr"] == 750
    end
  end

  describe "peer verifier grants" do
    test "previews an individual grant without mutating or auditing", %{mcp_conn: conn} do
      user =
        user_fixture(%{city: "Delhi", state: "Delhi"})
        |> activate()
        |> set_peer_progress(1)

      body =
        conn
        |> post(~p"/api/v1/admin/users/grant-peer-verifier", %{
          "identifier" => "@#{user.user_handle}",
          "credits" => 7,
          "dry_run" => true
        })
        |> json_response(200)

      assert body["status"] == "preview"
      assert body["mode"] == "individual"
      assert body["credits_to_set"] == 7
      assert body["target_count"] == 1
      assert [%{"id" => id, "peer_verified" => false}] = body["targets"]
      assert id == user.id

      unchanged = Repo.get!(User, user.id)
      refute unchanged.peer_verified
      assert unchanged.peer_vouches_received == 1
      assert unchanged.vouch_credits_remaining == 0
      assert grant_logs() == []
    end

    test "grants one member and audits the MCP action", %{mcp_conn: conn} do
      user =
        user_fixture(%{city: "Delhi", state: "Delhi"})
        |> activate()
        |> set_peer_progress(1)

      MarrylocalWeb.Endpoint.subscribe("user_notifications:#{user.id}")

      body =
        conn
        |> post(~p"/api/v1/admin/users/grant-peer-verifier", %{
          "identifier" => user.email,
          "credits" => 6,
          "dry_run" => false
        })
        |> json_response(200)

      assert body["status"] == "success"
      assert body["mode"] == "individual"
      assert body["credits_to_set"] == 6
      assert body["target_count"] == 1

      assert [
               %{
                 "id" => id,
                 "peer_verified" => true,
                 "is_peer_verifier" => true,
                 "is_available_to_vouch" => true,
                 "seed_verifier_status" => "approved",
                 "peer_vouches_received" => vouches,
                 "vouch_credits_remaining" => 6
               }
             ] = body["users"]

      assert id == user.id
      assert vouches == 3

      updated = Repo.get!(User, user.id)
      assert updated.peer_verified
      assert updated.is_peer_verifier
      assert updated.is_available_to_vouch
      assert updated.seed_verifier_status == "approved"
      assert updated.verified_at
      assert updated.peer_vouches_received == 3
      assert updated.vouch_credits_remaining == 6

      assert [log] = grant_logs()
      assert log.source == "mcp"
      assert log.action == "grant_peer_verifier"
      assert log.target_id == to_string(user.id)
      assert log.metadata["mode"] == "individual"
      assert log.metadata["credits"] == 6
      assert log.metadata["target_ids"] == [user.id]

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "user_notifications:" <> _,
        event: "peer_verification_updated",
        payload: %{
          reason: "admin_grant",
          peer_verified: true,
          is_peer_verifier: true,
          peer_vouches_received: 3,
          vouch_credits_remaining: 6
        }
      }
    end

    test "previews a city seed with profile-first, oldest-first ordering", %{mcp_conn: conn} do
      oldest =
        user_fixture(%{city: "Hyderabad", state: "Telangana"})
        |> activate()
        |> set_inserted_at(12)

      complete =
        user_fixture(%{city: "Hyderabad", state: "Telangana"})
        |> activate()
        |> set_inserted_at(9)
        |> set_avatar("avatar.png")

      newest =
        user_fixture(%{city: "Hyderabad", state: "Telangana"})
        |> activate()
        |> set_inserted_at(1)

      _already_verified =
        user_fixture(%{city: "Hyderabad", state: "Telangana"})
        |> activate()
        |> mark_peer_verified()

      _mumbai = user_fixture(%{city: "Mumbai", state: "Maharashtra"}) |> activate()
      inactive = user_fixture(%{city: "Hyderabad", state: "Telangana"}) |> deactivate()

      body =
        conn
        |> post(~p"/api/v1/admin/users/grant-peer-verifier", %{
          "state" => "Telangana",
          "city" => "Hyderabad",
          "limit" => 4,
          "credits" => 6,
          "dry_run" => true
        })
        |> json_response(200)

      assert body["status"] == "preview"
      assert body["mode"] == "city"
      assert body["target_count"] == 3
      assert body["credits_to_set"] == 6
      assert Enum.map(body["targets"], & &1["id"]) == [complete.id, oldest.id, newest.id]
      refute inactive.id in Enum.map(body["targets"], & &1["id"])

      refute Repo.get!(User, oldest.id).peer_verified
      refute Repo.get!(User, complete.id).peer_verified
      assert grant_logs() == []
    end

    test "seeds a city up to the limit and preserves higher vouch counts", %{mcp_conn: conn} do
      first =
        user_fixture(%{city: "Hyderabad", state: "Telangana"})
        |> activate()
        |> set_inserted_at(10)

      second =
        user_fixture(%{city: "Hyderabad", state: "Telangana"})
        |> activate()
        |> set_inserted_at(8)
        |> set_peer_progress(7)

      third =
        user_fixture(%{city: "Hyderabad", state: "Telangana"})
        |> activate()
        |> set_inserted_at(2)

      body =
        conn
        |> post(~p"/api/v1/admin/users/grant-peer-verifier", %{
          "state" => "Telangana",
          "city" => "Hyderabad",
          "limit" => 2,
          "credits" => 4,
          "dry_run" => false
        })
        |> json_response(200)

      assert body["status"] == "success"
      assert body["mode"] == "city"
      assert body["target_count"] == 2
      assert body["credits_to_set"] == 4
      assert Enum.map(body["users"], & &1["id"]) == [first.id, second.id]
      assert Enum.all?(body["users"], & &1["peer_verified"])

      assert %{"peer_vouches_received" => 3, "vouch_credits_remaining" => 4} =
               Enum.find(body["users"], &(&1["id"] == first.id))

      assert %{"peer_vouches_received" => 7, "vouch_credits_remaining" => 4} =
               Enum.find(body["users"], &(&1["id"] == second.id))

      assert Repo.get!(User, first.id).peer_verified
      assert Repo.get!(User, first.id).vouch_credits_remaining == 4
      assert Repo.get!(User, second.id).peer_vouches_received == 7
      refute Repo.get!(User, third.id).peer_verified

      assert [log] = grant_logs()
      assert log.source == "mcp"
      assert log.action == "grant_peer_verifier"
      assert log.target_id == nil
      assert log.metadata["mode"] == "city"
      assert log.metadata["credits"] == 4
      assert Enum.sort(log.metadata["target_ids"]) == Enum.sort([first.id, second.id])
    end

    test "rejects a grant without a target or location", %{mcp_conn: conn} do
      body =
        conn
        |> post(~p"/api/v1/admin/users/grant-peer-verifier", %{"credits" => 5})
        |> json_response(400)

      assert body["status"] == "error"
      assert body["error"] =~ "identifier"
    end

    test "rejects out-of-range credits and an inactive identifier", %{mcp_conn: conn} do
      user = user_fixture(%{city: "Delhi", state: "Delhi"}) |> activate()

      credits_body =
        conn
        |> post(~p"/api/v1/admin/users/grant-peer-verifier", %{
          "identifier" => user.email,
          "credits" => 21
        })
        |> json_response(422)

      assert credits_body["errors"]["credits"]

      inactive = user_fixture(%{city: "Delhi", state: "Delhi"}) |> deactivate()

      inactive_body =
        conn
        |> post(~p"/api/v1/admin/users/grant-peer-verifier", %{
          "identifier" => inactive.email,
          "credits" => 5
        })
        |> json_response(422)

      assert inactive_body["error"] =~ "not active"
    end
  end

  describe "seed verifier queue" do
    test "lists opted-in candidates with each city's approved progress", %{mcp_conn: conn} do
      for index <- 1..3 do
        insert_approved_seed("Hyderabad", "Telangana", index)
      end

      first = insert_seed_user("Hyderabad", "Telangana", "opted_in", 11)
      second = insert_seed_user("Hyderabad", "Telangana", "opted_in", 12)
      mumbai = insert_seed_user("Mumbai", "Maharashtra", "opted_in", 13)
      _invited = insert_seed_user("Hyderabad", "Telangana", "invited", 14)

      body =
        conn
        |> get(~p"/api/v1/admin/seed-verifiers")
        |> json_response(200)

      users = body["data"]["users"]
      ids = Enum.map(users, & &1["id"])

      assert body["data"]["target"] == 10
      assert body["data"]["count"] == 3
      assert Enum.sort(ids) == Enum.sort([first.id, second.id, mumbai.id])

      hyderabad = Enum.find(users, &(&1["id"] == first.id))
      assert hyderabad["seed_verifier_status"] == "opted_in"
      assert hyderabad["approved_in_city"] == 3
      assert hyderabad["target"] == 10
      assert hyderabad["slots_remaining"] == 7
      assert hyderabad["email"] == first.email

      mumbai_row = Enum.find(users, &(&1["id"] == mumbai.id))
      assert mumbai_row["approved_in_city"] == 0

      filtered =
        conn
        |> get(~p"/api/v1/admin/seed-verifiers", %{"city" => "Hyderabad"})
        |> json_response(200)

      assert filtered["data"]["count"] == 2

      invited =
        conn
        |> get(~p"/api/v1/admin/seed-verifiers", %{"status" => "invited"})
        |> json_response(200)

      assert invited["data"]["count"] == 1

      assert conn
             |> get(~p"/api/v1/admin/seed-verifiers", %{"status" => "bogus"})
             |> json_response(422)
             |> Map.fetch!("status") == "error"
    end

    test "previews a seed approval without mutating or auditing", %{mcp_conn: conn} do
      for index <- 1..2 do
        insert_approved_seed("Hyderabad", "Telangana", index)
      end

      candidate = insert_seed_user("Hyderabad", "Telangana", "opted_in", 21)

      body =
        conn
        |> post(~p"/api/v1/admin/seed-verifiers/approve", %{
          "identifier" => candidate.email,
          "credits" => 7,
          "notes" => "Verified Driving License via email",
          "dry_run" => true
        })
        |> json_response(200)

      assert body["status"] == "preview"
      assert body["data"]["approved_in_city"] == 2
      assert body["data"]["target"] == 10
      assert body["data"]["user"]["id"] == candidate.id
      assert body["data"]["user"]["email"] == candidate.email
      assert body["data"]["user"]["phone_number"] == candidate.phone_number
      assert body["data"]["changes"]["seed_verifier_status"] == "approved"
      assert body["data"]["changes"]["vouch_credits_remaining"] == 7

      unchanged = Repo.get!(User, candidate.id)
      assert unchanged.seed_verifier_status == "opted_in"
      refute unchanged.peer_verified
      refute unchanged.is_peer_verifier

      assert Repo.aggregate(
               from(l in AuditLog, where: l.action == "approve_seed_verifier"),
               :count,
               :id
             ) == 0
    end

    test "approves a candidate and audits source mcp", %{mcp_conn: conn} do
      for index <- 1..2 do
        insert_approved_seed("Hyderabad", "Telangana", index)
      end

      candidate = insert_seed_user("Hyderabad", "Telangana", "opted_in", 31)

      body =
        conn
        |> post(~p"/api/v1/admin/seed-verifiers/approve", %{
          "identifier" => "@#{candidate.user_handle}",
          "credits" => 5,
          "notes" => "Verified Driving License via email",
          "dry_run" => false
        })
        |> json_response(200)

      assert body["status"] == "success"
      assert body["threshold_reached"] == false
      assert body["data"]["approved_in_city"] == 3
      assert body["data"]["user"]["seed_verifier_status"] == "approved"
      assert body["data"]["user"]["is_peer_verifier"] == true
      assert body["data"]["user"]["vouch_credits_remaining"] == 5

      updated = Repo.get!(User, candidate.id)
      assert updated.seed_verifier_status == "approved"
      assert updated.peer_verified
      assert updated.is_peer_verifier
      assert updated.is_available_to_vouch
      assert updated.vouch_credits_remaining == 5
      assert updated.peer_vouches_received >= 3
      assert updated.verified_at

      log =
        Repo.one(
          from l in AuditLog,
            where: l.action == "approve_seed_verifier",
            order_by: [desc: l.id],
            limit: 1
        )

      assert log.source == "mcp"
      assert log.target_id == to_string(candidate.id)
      assert log.metadata["city"] == "Hyderabad"
      assert log.metadata["notes"] == "Verified Driving License via email"
    end

    test "reports when the tenth approval reaches the city threshold", %{mcp_conn: conn} do
      for index <- 1..9 do
        insert_approved_seed("Hyderabad", "Telangana", index)
      end

      candidate = insert_seed_user("Hyderabad", "Telangana", "opted_in", 41)

      body =
        conn
        |> post(~p"/api/v1/admin/seed-verifiers/approve", %{
          "identifier" => to_string(candidate.id),
          "dry_run" => false
        })
        |> json_response(200)

      assert body["threshold_reached"] == true
      assert body["data"]["approved_in_city"] == 10
      assert body["data"]["target"] == 10
      assert body["message"] =~ "threshold is reached"
    end

    test "requires an override for invited candidates and blocks opted-out members", %{
      mcp_conn: conn
    } do
      invited = insert_seed_user("Hyderabad", "Telangana", "invited", 51)
      opted_out = insert_seed_user("Hyderabad", "Telangana", "opted_out", 52)
      approved = insert_approved_seed("Hyderabad", "Telangana", 53)

      rejected =
        conn
        |> post(~p"/api/v1/admin/seed-verifiers/approve", %{
          "identifier" => invited.email,
          "dry_run" => false
        })
        |> json_response(422)

      assert rejected["code"] == "seed_status_not_opted_in"
      refute Repo.get!(User, invited.id).peer_verified

      accepted =
        conn
        |> post(~p"/api/v1/admin/seed-verifiers/approve", %{
          "identifier" => invited.email,
          "dry_run" => false,
          "allow_override" => true
        })
        |> json_response(200)

      assert accepted["data"]["user"]["seed_verifier_status"] == "approved"

      opted_out_response =
        conn
        |> post(~p"/api/v1/admin/seed-verifiers/approve", %{
          "identifier" => opted_out.email,
          "dry_run" => false,
          "allow_override" => true
        })
        |> json_response(422)

      assert opted_out_response["code"] == "seed_status_opted_out"

      already_approved =
        conn
        |> post(~p"/api/v1/admin/seed-verifiers/approve", %{
          "identifier" => approved.email,
          "dry_run" => false
        })
        |> json_response(422)

      assert already_approved["code"] == "already_approved"

      not_found =
        conn
        |> post(~p"/api/v1/admin/seed-verifiers/approve", %{
          "identifier" => "missing@example.com",
          "dry_run" => true
        })
        |> json_response(404)

      assert not_found["status"] == "error"
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp activate(user) do
    user
    |> Ecto.Changeset.change(user_state: :active)
    |> Repo.update!()
  end

  defp deactivate(user) do
    user
    |> Ecto.Changeset.change(user_state: :inactive)
    |> Repo.update!()
  end

  defp set_inserted_at(user, days_ago) do
    inserted_at = DateTime.add(DateTime.utc_now(:second), -days_ago, :day)

    user
    |> Ecto.Changeset.change(inserted_at: inserted_at, updated_at: inserted_at)
    |> Repo.update!()
  end

  defp set_peer_progress(user, vouches) do
    user
    |> Ecto.Changeset.change(peer_vouches_received: vouches)
    |> Repo.update!()
  end

  defp mark_peer_verified(user) do
    user
    |> Ecto.Changeset.change(
      peer_verified: true,
      peer_vouches_received: 3,
      vouch_credits_remaining: 5
    )
    |> Repo.update!()
  end

  defp set_avatar(user, file_name) do
    user
    |> Ecto.Changeset.change(avatar: %{file_name: file_name, updated_at: nil})
    |> Repo.update!()
  end

  defp grant_logs do
    Repo.all(
      from l in AuditLog,
        where: l.action == "grant_peer_verifier",
        order_by: [asc: l.id]
    )
  end

  defp insert_seed_user(city, state, status, index) do
    user_fixture(%{city: city, state: state, first_name: "Seed#{index}"})
    |> activate()
    |> Ecto.Changeset.change(seed_verifier_status: status)
    |> Repo.update!()
  end

  defp insert_approved_seed(city, state, index) do
    insert_seed_user(city, state, "approved", index)
    |> Ecto.Changeset.change(
      peer_verified: true,
      is_peer_verifier: true,
      peer_vouches_received: 3,
      vouch_credits_remaining: 5,
      verified_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
    |> Repo.update!()
  end

  defp insert_invoice(user, number) do
    Repo.insert!(%Invoice{
      user_id: user.id,
      invoice_number: number,
      item_type: "annual_fee",
      description: "Annual membership",
      base_amount_inr: Decimal.new("500.00"),
      gst_amount_inr: Decimal.new("90.00"),
      total_amount_inr: Decimal.new("590.00"),
      status: "paid"
    })
  end

  defp insert_verification(user, opts) do
    hours_ago = Keyword.fetch!(opts, :hours_ago)
    inserted_at = DateTime.add(DateTime.utc_now(:second), -hours_ago, :hour)

    Repo.insert!(%IdentityVerification{
      user_id: user.id,
      document_type: "passport",
      document_number: "P#{System.unique_integer([:positive])}",
      identity_hash: "hash-#{System.unique_integer([:positive])}",
      document_image: %{file_name: "", updated_at: nil},
      status: "pending_admin_review",
      inserted_at: inserted_at,
      updated_at: inserted_at
    })
  end
end

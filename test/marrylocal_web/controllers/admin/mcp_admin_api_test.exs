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

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

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

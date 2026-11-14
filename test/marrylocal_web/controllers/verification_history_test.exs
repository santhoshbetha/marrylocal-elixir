defmodule MarrylocalWeb.VerificationHistoryTest do
  use MarrylocalWeb.ConnCase, async: false

  import Ecto.Query
  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts
  alias Marrylocal.Accounts.IdentityVerification
  alias Marrylocal.Notifications.Notification
  alias Marrylocal.Repo

  setup %{conn: conn} do
    user = user_fixture(%{city: "Delhi", state: "Delhi"})
    admin = user_fixture() |> Ecto.Changeset.change(role: :admin) |> Repo.update!()

    {:ok,
     conn: conn,
     user: user,
     admin: admin,
     user_token: Accounts.generate_user_session_token(user),
     admin_token: Accounts.generate_user_session_token(admin)}
  end

  test "returns every submission newest first with decisions and reasons", %{
    conn: conn,
    user: user,
    user_token: token
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rejected =
      insert_verification(user.id, %{
        status: "rejected",
        submitted_at: DateTime.add(now, -10, :day),
        reviewed_at: DateTime.add(now, -9, :day),
        rejection_reason: "Photo was blurred."
      })

    pending =
      insert_verification(user.id, %{
        status: "pending_admin_review",
        submitted_at: now
      })

    body =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/api/v1/verifications/history")
      |> json_response(200)

    verifications = body["data"]["verifications"]
    assert length(verifications) == 2
    assert Enum.map(verifications, & &1["id"]) == [pending.id, rejected.id]

    [latest, previous] = verifications
    assert latest["decision"] == "pending"
    assert latest["submitted_at"]

    assert previous["decision"] == "rejected"
    assert previous["rejection_reason"] == "Photo was blurred."
    assert previous["reviewed_at"]
  end

  test "admins can inspect one member's verification history", %{
    conn: conn,
    user: user,
    admin_token: admin_token
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    insert_verification(user.id, %{status: "verified", submitted_at: now, reviewed_at: now})

    insert_verification(user.id, %{
      status: "rejected",
      submitted_at: now,
      rejection_reason: "Expired."
    })

    body =
      conn
      |> put_req_header("authorization", "Bearer #{admin_token}")
      |> get(~p"/api/v1/admin/users/#{user.id}/verifications")
      |> json_response(200)

    assert length(body["data"]["verifications"]) == 2
    assert Enum.any?(body["data"]["verifications"], &(&1["status"] == "verified"))
  end

  test "approval stamps reviewer metadata and delivers an in-app notification", %{
    conn: conn,
    user: user,
    admin: admin,
    admin_token: admin_token,
    user_token: user_token
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    verification =
      insert_verification(user.id, %{status: "pending_admin_review", submitted_at: now})

    MarrylocalWeb.Endpoint.subscribe("user_notifications:#{user.id}")

    body =
      conn
      |> put_req_header("authorization", "Bearer #{admin_token}")
      |> post(~p"/api/v1/admin/verifications/#{verification.id}/approve")
      |> json_response(200)

    updated = body["data"]["verification"]
    assert updated["status"] == "verified"
    assert updated["decision"] == "approved"
    assert updated["reviewed_by_admin_id"] == admin.id
    assert updated["reviewed_at"]

    notification =
      Repo.one(
        from n in Notification,
          where: n.user_id == ^user.id and n.type == :verification_update,
          order_by: [desc: n.id],
          limit: 1
      )

    assert notification
    assert notification.is_read == false
    assert notification.title == "Identity Verification Approved"
    assert notification.body =~ "Passport verification has been approved on"
    assert notification.body =~ "ID Verified badge is now active"

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "user_notifications:" <> _,
      event: "new_notification",
      payload: %{title: "Identity Verification Approved", type: "verification_update"}
    }

    feed =
      conn
      |> put_req_header("authorization", "Bearer #{user_token}")
      |> get(~p"/api/v1/notifications")
      |> json_response(200)

    assert Enum.any?(
             feed["data"]["notifications"],
             &(&1["title"] == "Identity Verification Approved")
           )
  end

  test "rejection includes the reason in the in-app notification", %{
    conn: conn,
    user: user,
    admin: admin,
    admin_token: admin_token
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    verification =
      insert_verification(user.id, %{status: "pending_admin_review", submitted_at: now})

    reason = "The document number is unreadable."

    body =
      conn
      |> put_req_header("authorization", "Bearer #{admin_token}")
      |> post(~p"/api/v1/admin/verifications/#{verification.id}/reject", %{"reason" => reason})
      |> json_response(200)

    updated = body["data"]["verification"]
    assert updated["status"] == "rejected"
    assert updated["decision"] == "rejected"
    assert updated["rejection_reason"] == reason
    assert updated["reviewed_by_admin_id"] == admin.id
    assert updated["reviewed_at"]

    notification =
      Repo.one(
        from n in Notification,
          where: n.user_id == ^user.id and n.type == :verification_update,
          order_by: [desc: n.id],
          limit: 1
      )

    assert notification.title == "Identity Verification Update"
    assert notification.body =~ "could not be verified"
    assert notification.body =~ reason
    assert notification.body =~ "submit a clearer document"
  end

  defp insert_verification(user_id, attrs) do
    unique = System.unique_integer([:positive])

    %IdentityVerification{
      user_id: user_id,
      document_type: "passport",
      document_number: "P#{unique}",
      identity_hash: "verification-history-#{unique}",
      document_image: %{file_name: "", updated_at: nil},
      status: Map.get(attrs, :status, "pending_admin_review"),
      submitted_at: Map.get(attrs, :submitted_at),
      reviewed_at: Map.get(attrs, :reviewed_at),
      rejection_reason: Map.get(attrs, :rejection_reason)
    }
    |> Repo.insert!()
  end
end

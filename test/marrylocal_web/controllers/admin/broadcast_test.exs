defmodule MarrylocalWeb.Admin.BroadcastTest do
  use MarrylocalWeb.ConnCase, async: true
  use Oban.Testing, repo: Marrylocal.Repo

  import Ecto.Query
  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts
  alias Marrylocal.Notifications.Notification
  alias Marrylocal.Repo
  alias Marrylocal.Workers.SystemNotificationWorker

  defp admin_conn(conn) do
    admin = user_fixture()

    {:ok, admin} =
      admin
      |> Ecto.Changeset.change(role: :admin)
      |> Repo.update()

    token = Accounts.generate_user_session_token(admin)

    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  test "system notification worker inserts and broadcasts in the user topic", %{conn: _conn} do
    female = user_fixture(%{city: "Bangalore", state: "Karnataka", gender: "Female"})
    male = user_fixture(%{city: "Bangalore", state: "Karnataka", gender: "Male"})

    MarrylocalWeb.Endpoint.subscribe("user_notifications:#{female.id}")
    MarrylocalWeb.Endpoint.subscribe("user_notifications:#{male.id}")

    args = %{
      "title" => "Bangalore Meetup Alert",
      "body" => "Join us this weekend.",
      "target_type" => "location",
      "state" => "Karnataka",
      "city" => "Bangalore",
      "gender" => "Female"
    }

    assert :ok = SystemNotificationWorker.perform(%Oban.Job{args: args})

    notifications =
      Repo.all(from n in Notification, where: n.title == ^"Bangalore Meetup Alert")

    assert length(notifications) == 1
    assert hd(notifications).user_id == female.id

    assert_receive %Phoenix.Socket.Broadcast{
      event: "new_notification",
      payload: %{title: "Bangalore Meetup Alert", type: "system"}
    }

    refute_received %Phoenix.Socket.Broadcast{
      topic: "user_notifications:" <> _,
      payload: %{title: "Bangalore Meetup Alert"}
    }
  end

  test "admin notification endpoint queues a targeted broadcast", %{conn: conn} do
    conn = admin_conn(conn)
    _female = user_fixture(%{city: "Bangalore", state: "Karnataka", gender: "Female"})
    _male = user_fixture(%{city: "Bangalore", state: "Karnataka", gender: "Male"})

    conn =
      post(conn, ~p"/api/v1/admin/notifications/broadcast", %{
        "target_type" => "location",
        "state" => "Karnataka",
        "city" => "Bangalore",
        "gender" => "Female",
        "title" => "Bangalore Meetup Alert",
        "body" => "Join us this weekend."
      })

    body = json_response(conn, 202)
    assert body["status"] == "queued"
    assert body["estimated_recipients"] == 1
    assert_enqueued(worker: SystemNotificationWorker)
  end

  test "admin notification endpoint rejects invalid targeting", %{conn: conn} do
    conn = admin_conn(conn)

    conn =
      post(conn, ~p"/api/v1/admin/notifications/broadcast", %{
        "target_type" => "individual",
        "identifiers" => [],
        "title" => "Hello",
        "body" => "Body"
      })

    assert json_response(conn, 422)["status"] == "error"
  end

  test "preview-count resolves location recipients and bulk-send queues them", %{conn: conn} do
    conn = admin_conn(conn)
    female = user_fixture(%{city: "Delhi", state: "Delhi", gender: "Female"})
    _male = user_fixture(%{city: "Delhi", state: "Delhi", gender: "Male"})

    preview =
      get(conn, ~p"/api/v1/admin/emails/preview-count", %{
        "mode" => "location",
        "state" => "Delhi",
        "city" => "Delhi",
        "gender" => "Female"
      })

    assert json_response(preview, 200)["recipient_count"] == 1

    conn =
      post(conn, ~p"/api/v1/admin/emails/bulk-send", %{
        "mode" => "location",
        "state" => "Delhi",
        "city" => "Delhi",
        "gender" => "Female",
        "subject" => "Hello",
        "content" => "<p>Body</p>"
      })

    assert json_response(conn, 202) == %{"status" => "queued", "queued_count" => 1}
    assert_enqueued(worker: Marrylocal.Workers.BulkEmailWorker)

    job =
      Repo.one(
        from j in Oban.Job,
          where: j.worker == "Marrylocal.Workers.BulkEmailWorker",
          order_by: [desc: j.id],
          limit: 1
      )

    assert job.args["emails"] == [female.email]
  end

  test "manual bulk-send accepts explicit addresses", %{conn: conn} do
    conn = admin_conn(conn)

    conn =
      post(conn, ~p"/api/v1/admin/emails/bulk-send", %{
        "mode" => "manual",
        "emails" => ["one@example.com", "two@example.com"],
        "gender" => "All",
        "subject" => "Manual",
        "content" => "<p>Body</p>"
      })

    assert json_response(conn, 202) == %{"status" => "queued", "queued_count" => 2}
  end
end

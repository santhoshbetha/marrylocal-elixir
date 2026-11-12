defmodule MarrylocalWeb.Admin.EmailControllerTest do
  use MarrylocalWeb.ConnCase, async: true

  import Ecto.Query
  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts
  alias Marrylocal.Repo

  defp admin_conn(conn) do
    admin = user_fixture()
    {:ok, admin} = admin |> Ecto.Changeset.change(role: :admin) |> Repo.update()
    token = Accounts.generate_user_session_token(admin)

    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  test "queues valid addresses and filters duplicates and invalid values", %{conn: conn} do
    conn = admin_conn(conn)

    conn =
      post(conn, ~p"/api/v1/admin/emails/bulk-send", %{
        "emails" => [
          "one@example.com",
          "not-an-email",
          "two@example.com",
          " one@example.com "
        ],
        "subject" => "  Hello  ",
        "content" => " <p>Hi</p> "
      })

    assert json_response(conn, 202) == %{"status" => "queued", "queued_count" => 2}

    job =
      Repo.one(
        from j in Oban.Job,
          where: j.worker == "Marrylocal.Workers.BulkEmailWorker"
      )

    assert job.queue == "mailers"
    assert job.max_attempts == 3
    assert job.args["emails"] == ["one@example.com", "two@example.com"]
    assert job.args["subject"] == "Hello"
    assert job.args["content"] == "<p>Hi</p>"
  end

  test "rejects empty, invalid, or blank payloads", %{conn: conn} do
    conn = admin_conn(conn)
    path = ~p"/api/v1/admin/emails/bulk-send"

    assert json_response(
             post(conn, path, %{"emails" => [], "subject" => "x", "content" => "y"}),
             422
           )

    assert json_response(
             post(conn, path, %{"emails" => ["not-an-email"], "subject" => "x", "content" => "y"}),
             422
           )

    assert json_response(
             post(conn, path, %{
               "emails" => ["a@example.com"],
               "subject" => "   ",
               "content" => "y"
             }),
             422
           )

    assert json_response(
             post(conn, path, %{"emails" => ["a@example.com"], "subject" => "x", "content" => ""}),
             422
           )
  end

  test "rejects non-admin callers with 403", %{conn: conn} do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user)
    conn = put_req_header(conn, "authorization", "Bearer #{token}")

    conn =
      post(conn, ~p"/api/v1/admin/emails/bulk-send", %{
        "emails" => ["a@example.com"],
        "subject" => "x",
        "content" => "y"
      })

    assert json_response(conn, 403)
  end
end

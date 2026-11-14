defmodule MarrylocalWeb.ReportControllerTest do
  use MarrylocalWeb.ConnCase, async: false

  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts
  alias Marrylocal.Repo
  alias Marrylocal.Reports

  setup %{conn: conn} do
    reporter = active_user(%{gender: "Female", city: "Delhi", state: "Delhi"})
    target = active_user(%{gender: "Male", city: "Delhi", state: "Delhi"})
    token = Accounts.generate_user_session_token(reporter)

    {:ok, conn: conn, reporter: reporter, target: target, token: token}
  end

  test "creates a report for another member", %{conn: conn, target: target, token: token} do
    body =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(~p"/api/v1/reports", %{
        "reported_user_id" => target.id,
        "reason" => "harassment",
        "details" => "Sent abusive messages."
      })
      |> json_response(201)

    assert body["status"] == "success"
    assert body["message"] =~ "safety team"
    assert body["data"]["report"]["reported_user_id"] == target.id
    assert body["data"]["report"]["status"] == "pending"
  end

  test "rejects self reports", %{conn: conn, reporter: reporter, token: token} do
    body =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(~p"/api/v1/reports", %{
        "reported_user_id" => reporter.id,
        "reason" => "other"
      })
      |> json_response(422)

    assert body["code"] == "self_report"
  end

  test "rejects invalid reasons and unknown members", %{
    conn: conn,
    target: target,
    token: token
  } do
    invalid_reason =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(~p"/api/v1/reports", %{
        "reported_user_id" => target.id,
        "reason" => "not_a_reason"
      })
      |> json_response(422)

    assert invalid_reason["code"] == "invalid_reason"

    unknown =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(~p"/api/v1/reports", %{
        "reported_user_id" => 999_999_999,
        "reason" => "other"
      })
      |> json_response(422)

    assert unknown["code"] == "invalid_user"
  end

  test "blocks duplicate pending reports", %{conn: conn, target: target, token: token} do
    # Create a pending report from a different reporter; it should not block
    # this reporter's first report, only their own duplicate.
    other = active_user(%{gender: "Female", city: "Delhi", state: "Delhi"})

    {:ok, _} =
      Reports.create_report(other, %{"reported_user_id" => target.id, "reason" => "other"})

    body =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(~p"/api/v1/reports", %{
        "reported_user_id" => target.id,
        "reason" => "harassment"
      })
      |> json_response(201)

    assert body["status"] == "success"

    duplicate =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(~p"/api/v1/reports", %{
        "reported_user_id" => target.id,
        "reason" => "scam_or_spam"
      })
      |> json_response(422)

    assert duplicate["code"] == "duplicate_pending_report"
  end

  test "rate limits to five reports per 24 hours", %{conn: conn, reporter: reporter, token: token} do
    targets =
      for index <- 1..6 do
        active_user(%{
          gender: "Male",
          city: "Delhi",
          state: "Delhi",
          first_name: "Rate#{index}"
        })
      end

    for target <- Enum.take(targets, 5) do
      assert {:ok, _} =
               Reports.create_report(reporter, %{
                 "reported_user_id" => target.id,
                 "reason" => "other"
               })
    end

    last = List.last(targets)

    body =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(~p"/api/v1/reports", %{
        "reported_user_id" => last.id,
        "reason" => "other"
      })
      |> json_response(429)

    assert body["code"] == "report_rate_limited"
  end

  defp active_user(attrs) do
    user_fixture(attrs)
    |> Ecto.Changeset.change(user_state: :active)
    |> Repo.update!()
  end
end

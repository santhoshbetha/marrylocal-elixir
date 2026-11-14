defmodule Marrylocal.ReportsTest do
  use Marrylocal.DataCase, async: false

  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts.User
  alias Marrylocal.Repo
  alias Marrylocal.Reports

  setup do
    reporter = active_user(%{gender: "Female", city: "Delhi", state: "Delhi"})
    target = active_user(%{gender: "Male", city: "Delhi", state: "Delhi"})
    admin = active_user(%{role: :admin})

    {:ok, reporter: reporter, target: target, admin: admin}
  end

  test "creates one pending report per reporter/target pair", %{
    reporter: reporter,
    target: target
  } do
    assert {:ok, report} =
             Reports.create_report(reporter, %{
               "reported_user_id" => target.id,
               "reason" => "harassment",
               "details" => "Sent abusive messages."
             })

    assert report.status == "pending"
    assert report.reporter_id == reporter.id
    assert report.reported_user_id == target.id

    assert {:error, :duplicate_pending} =
             Reports.create_report(reporter, %{
               "reported_user_id" => target.id,
               "reason" => "scam_or_spam"
             })
  end

  test "resolved reports do not block a new report", %{
    reporter: reporter,
    target: target,
    admin: admin
  } do
    assert {:ok, report} =
             Reports.create_report(reporter, %{
               "reported_user_id" => target.id,
               "reason" => "harassment"
             })

    assert {:ok, dismissed} =
             Reports.review_report(report, admin, %{"status" => "dismissed"})

    assert dismissed.status == "dismissed"
    assert dismissed.reviewed_by_admin_id == admin.id
    assert dismissed.reviewed_at

    assert {:ok, _new_report} =
             Reports.create_report(reporter, %{
               "reported_user_id" => target.id,
               "reason" => "scam_or_spam"
             })
  end

  test "rejects self reports, invalid reasons, and unknown targets", %{reporter: reporter} do
    assert {:error, :self_report} =
             Reports.create_report(reporter, %{
               "reported_user_id" => reporter.id,
               "reason" => "other"
             })

    assert {:error, :invalid_reason} =
             Reports.create_report(reporter, %{
               "reported_user_id" => reporter.id + 1,
               "reason" => "not_a_reason"
             })

    assert {:error, :invalid_user} =
             Reports.create_report(reporter, %{
               "reported_user_id" => 999_999_999,
               "reason" => "other"
             })
  end

  test "limits a reporter to five reports per 24 hours", %{reporter: reporter} do
    targets =
      for index <- 1..6 do
        active_user(%{
          gender: "Male",
          city: "Delhi",
          state: "Delhi",
          first_name: "Target#{index}"
        })
      end

    for target <- Enum.take(targets, 5) do
      assert {:ok, _report} =
               Reports.create_report(reporter, %{
                 "reported_user_id" => target.id,
                 "reason" => "other"
               })
    end

    last = List.last(targets)

    assert {:error, :rate_limited} =
             Reports.create_report(reporter, %{
               "reported_user_id" => last.id,
               "reason" => "other"
             })
  end

  test "review_and_suspend deactivates the reported member and lists totals", %{
    reporter: reporter,
    target: target,
    admin: admin
  } do
    assert {:ok, report} =
             Reports.create_report(reporter, %{
               "reported_user_id" => target.id,
               "reason" => "fake_profile",
               "details" => "Stolen photos."
             })

    assert {:ok, resolved} =
             Reports.review_report(report, admin, %{
               "status" => "reviewed_action_taken",
               "suspend_user" => true,
               "admin_notes" => "Confirmed stolen photos."
             })

    assert resolved.status == "reviewed_action_taken"
    assert resolved.admin_notes == "Confirmed stolen photos."
    assert Repo.get!(User, target.id).user_state == :inactive

    assert {:ok, rows} = Reports.list_reports(%{"status" => "reviewed_action_taken"})
    assert [{listed, count}] = rows
    assert listed.id == resolved.id
    assert count == 1
    assert listed.reported_user.id == target.id
    assert listed.reporter.id == reporter.id
  end

  test "rejects invalid statuses and re-reviewing", %{
    reporter: reporter,
    target: target,
    admin: admin
  } do
    assert {:ok, report} =
             Reports.create_report(reporter, %{
               "reported_user_id" => target.id,
               "reason" => "other"
             })

    assert {:error, :invalid_status} =
             Reports.review_report(report, admin, %{"status" => "pending"})

    assert {:ok, resolved} =
             Reports.review_report(report, admin, %{"status" => "dismissed"})

    assert {:error, :already_reviewed} =
             Reports.review_report(resolved, admin, %{"status" => "dismissed"})

    assert {:error, :invalid_status} = Reports.list_reports(%{"status" => "bogus"})
  end

  defp active_user(attrs) do
    user = user_fixture(attrs)

    changes =
      if attrs[:role],
        do: %{user_state: :active, role: attrs[:role]},
        else: %{user_state: :active}

    user
    |> Ecto.Changeset.change(changes)
    |> Repo.update!()
  end
end

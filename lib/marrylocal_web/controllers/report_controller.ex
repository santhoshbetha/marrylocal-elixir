defmodule MarrylocalWeb.ReportController do
  @moduledoc """
  Member-facing safety report submission.
  """

  use MarrylocalWeb, :controller

  alias Marrylocal.Reports

  @doc "POST /api/v1/reports"
  def create(conn, params) do
    reporter = conn.assigns.current_user

    case Reports.create_report(reporter, params) do
      {:ok, report} ->
        conn
        |> put_status(:created)
        |> json(%{
          status: "success",
          message: "Thank you. Your report has been submitted to our safety team.",
          data: %{report: serialize(report)}
        })

      {:error, :self_report} ->
        error(conn, :unprocessable_entity, "self_report", "You cannot report your own profile.")

      {:error, :invalid_user} ->
        error(conn, :unprocessable_entity, "invalid_user", "reported_user_id is required.")

      {:error, :invalid_reason} ->
        error(
          conn,
          :unprocessable_entity,
          "invalid_reason",
          "Choose one of the supported report reasons."
        )

      {:error, :duplicate_pending} ->
        error(
          conn,
          :unprocessable_entity,
          "duplicate_pending_report",
          "You already have an open report against this member. Our safety team is reviewing it."
        )

      {:error, :rate_limited} ->
        error(
          conn,
          :too_many_requests,
          "report_rate_limited",
          "You can submit up to five reports per 24 hours. Please try again later."
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", message: "Report validation failed", errors: errors})
    end
  end

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{status: "error", code: code, message: message})
  end

  defp serialize(report) do
    %{
      id: report.id,
      reporter_id: report.reporter_id,
      reported_user_id: report.reported_user_id,
      reason: report.reason,
      details: report.details,
      status: report.status,
      inserted_at: report.inserted_at
    }
  end
end

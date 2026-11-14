defmodule MarrylocalWeb.Admin.ReportController do
  @moduledoc """
  Administrative moderation queue for member safety reports.
  """

  use MarrylocalWeb, :controller

  alias Marrylocal.Admin.Audit
  alias Marrylocal.Reports
  alias Marrylocal.Reports.UserReport

  @doc "GET /api/v1/admin/reports"
  def index(conn, params) do
    case Reports.list_reports(params) do
      {:ok, rows} ->
        json(conn, %{
          status: "success",
          data: %{
            reports: Enum.map(rows, fn {report, count} -> serialize(report, count) end),
            count: length(rows),
            status: params["status"] || "pending"
          }
        })

      {:error, :invalid_status} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          status: "error",
          message: "status must be pending, reviewed_action_taken, or dismissed"
        })
    end
  end

  @doc "GET /api/v1/admin/reports/:id"
  def show(conn, %{"id" => id}) do
    case Reports.get_report(id) do
      nil ->
        not_found(conn)

      %UserReport{} = report ->
        count =
          Map.get(Reports.report_counts([report.reported_user_id]), report.reported_user_id, 0)

        json(conn, %{status: "success", data: %{report: serialize(report, count)}})
    end
  end

  @doc "PATCH /api/v1/admin/reports/:id"
  def update(conn, %{"id" => id} = params) do
    case Reports.get_report(id) do
      nil ->
        not_found(conn)

      %UserReport{} = report ->
        case Reports.review_report(report, conn.assigns.current_user, params) do
          {:ok, updated} ->
            Audit.record(conn, "admin.report.review", updated.id, %{
              status: updated.status,
              reported_user_id: updated.reported_user_id,
              suspend_user: truthy?(params["suspend_user"]),
              admin_notes: updated.admin_notes
            })

            count =
              Map.get(
                Reports.report_counts([updated.reported_user_id]),
                updated.reported_user_id,
                0
              )

            json(conn, %{
              status: "success",
              message: "Report #{updated.status}.",
              data: %{report: serialize(updated, count)}
            })

          {:error, :already_reviewed} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{status: "error", message: "This report has already been reviewed."})

          {:error, :invalid_status} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{
              status: "error",
              message: "status must be reviewed_action_taken or dismissed"
            })

          {:error, %Ecto.Changeset{} = changeset} ->
            errors = Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

            conn
            |> put_status(:unprocessable_entity)
            |> json(%{status: "error", message: "Report update failed", errors: errors})

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{status: "error", message: "Report update failed: #{inspect(reason)}"})
        end
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{status: "error", message: "Report not found."})
  end

  defp serialize(report, report_count) do
    %{
      id: report.id,
      reason: report.reason,
      details: report.details,
      status: report.status,
      admin_notes: report.admin_notes,
      reviewed_at: report.reviewed_at,
      reviewed_by_admin_id: report.reviewed_by_admin_id,
      inserted_at: report.inserted_at,
      reporter: summary(report.reporter),
      reported_user: summary(report.reported_user),
      reported_user_report_count: report_count
    }
  end

  defp summary(nil), do: nil

  defp summary(user) do
    %{
      id: user.id,
      first_name: user.first_name,
      last_name: user.last_name,
      email: user.email,
      user_handle: user.user_handle,
      city: user.city,
      user_state: user.user_state,
      phone_number: user.phone_number
    }
  end

  defp truthy?(value) when value in [true, 1, "1", "true", "TRUE"], do: true
  defp truthy?(_value), do: false
end

defmodule MarrylocalWeb.AdminVerificationController do
  @moduledoc """
  Sudo-guarded administrative identity-verification review endpoints.
  """

  use MarrylocalWeb, :controller

  alias Marrylocal.Accounts.Verifications
  alias Marrylocal.Admin.Audit
  alias MarrylocalWeb.IdentityVerificationJSON

  def index(conn, params) do
    verifications = Verifications.list(params)

    conn
    |> put_status(:ok)
    |> json(%{
      status: "success",
      data: %{
        verifications: Enum.map(verifications, &IdentityVerificationJSON.data/1)
      }
    })
  end

  def show(conn, %{"id" => id}) do
    case Verifications.get(id) do
      nil ->
        not_found(conn)

      verification ->
        json(conn, %{
          status: "success",
          data: %{verification: IdentityVerificationJSON.data(verification)}
        })
    end
  end

  def approve(conn, %{"id" => id}) do
    admin_id = conn.assigns.current_user.id

    with %{} = verification <- Verifications.get(id),
         {:ok, updated} <- Verifications.approve(verification, admin_id) do
      Audit.record(conn, "admin.verification.approve", updated.id, %{
        user_id: updated.user_id,
        document_type: updated.document_type
      })

      conn
      |> put_status(:ok)
      |> json(%{
        status: "success",
        message: "Verification approved and document purged.",
        data: %{verification: IdentityVerificationJSON.data(updated)}
      })
    else
      nil -> not_found(conn)
      {:error, reason} -> handle_error(conn, reason)
    end
  end

  def reject(conn, %{"id" => id} = params) do
    reason = params["reason"] || params["rejection_reason"]
    admin_id = conn.assigns.current_user.id

    with {:ok, reason} <- normalize_reason(reason),
         %{} = verification <- Verifications.get(id),
         {:ok, updated} <- Verifications.reject(verification, reason, admin_id) do
      Audit.record(conn, "admin.verification.reject", updated.id, %{
        user_id: updated.user_id,
        document_type: updated.document_type,
        reason: reason
      })

      conn
      |> put_status(:ok)
      |> json(%{
        status: "success",
        message: "Verification rejected and document purged.",
        data: %{verification: IdentityVerificationJSON.data(updated)}
      })
    else
      nil -> not_found(conn)
      {:error, :rejection_reason_required} -> missing_reason(conn)
      {:error, reason} -> handle_error(conn, reason)
    end
  end

  defp normalize_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> {:error, :rejection_reason_required}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_reason(_reason), do: {:error, :rejection_reason_required}

  defp missing_reason(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      status: "error",
      code: "rejection_reason_required",
      message: "A rejection reason is required."
    })
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{status: "error", message: "Verification not found."})
  end

  defp handle_error(conn, %Ecto.Changeset{} = changeset) do
    errors = Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{status: "error", message: "Validation failed", errors: errors})
  end

  defp handle_error(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{status: "error", message: "Verification action failed: #{inspect(reason)}"})
  end
end

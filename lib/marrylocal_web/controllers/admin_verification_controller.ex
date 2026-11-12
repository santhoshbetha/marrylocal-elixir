defmodule MarrylocalWeb.AdminVerificationController do
  @moduledoc """
  Sudo-guarded administrative identity-verification review endpoints.
  """

  use MarrylocalWeb, :controller

  alias Marrylocal.Accounts.Verifications
  alias MarrylocalWeb.IdentityVerificationJSON

  def index(conn, _params) do
    verifications = Verifications.list_pending()

    conn
    |> put_status(:ok)
    |> json(%{
      status: "success",
      data: %{
        verifications: Enum.map(verifications, &IdentityVerificationJSON.data/1)
      }
    })
  end

  def approve(conn, %{"id" => id}) do
    with %{} = verification <- Verifications.get(id),
         {:ok, updated} <- Verifications.approve(verification) do
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

    with {:ok, reason} <- normalize_reason(reason),
         %{} = verification <- Verifications.get(id),
         {:ok, updated} <- Verifications.reject(verification, reason) do
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

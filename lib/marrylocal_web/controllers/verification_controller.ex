defmodule MarrylocalWeb.VerificationController do
  @moduledoc """
  Authenticated identity-verification submission endpoint.

  Accepts multipart form data with `document_type`, `document_number`, and a
  `document_image` upload. The bearer user owns the resulting row; no user id
  is accepted from the payload.
  """

  use MarrylocalWeb, :controller

  alias Marrylocal.Accounts.Verifications
  alias MarrylocalWeb.IdentityVerificationJSON

  @document_types ~w(passport license)

  @doc "GET /api/v1/verifications/me"
  def show(conn, _params) do
    user = conn.assigns.current_user
    verification = Verifications.get_for_user(user.id)

    conn
    |> put_status(:ok)
    |> json(%{
      status: "success",
      data: %{
        verification: verification && IdentityVerificationJSON.owner(verification)
      }
    })
  end

  def create(conn, params) do
    user = conn.assigns.current_user

    with {:ok, attrs} <- extract_submission(params),
         {:ok, verification} <- Verifications.submit(user, attrs) do
      conn
      |> put_status(:created)
      |> json(%{
        status: "success",
        message: "Verification document uploaded successfully.",
        data: %{verification: IdentityVerificationJSON.owner(verification)}
      })
    else
      {:error, :already_verified} ->
        conn
        |> put_status(:conflict)
        |> json(%{status: "error", message: "This account is already identity verified."})

      {:error, :duplicate_identity} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          status: "error",
          code: "duplicate_identity",
          message: "This document number is already claimed by another verified account."
        })

      {:error, :missing_document_image} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          status: "error",
          code: "missing_document_image",
          message: "Attach a document image under the `document_image` field."
        })

      {:error, :invalid_document_type} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          status: "error",
          code: "invalid_document_type",
          message: "document_type must be passport or license."
        })

      {:error, :invalid_document_number} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          status: "error",
          code: "invalid_document_number",
          message: "document_number is required."
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        validation_error(conn, changeset)

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          status: "error",
          message: "Verification submission failed: #{inspect(reason)}"
        })
    end
  end

  defp extract_submission(params) do
    source = params["verification"] || params
    document_type = source["document_type"] || source["type"]
    document_number = source["document_number"] || source["documentNumber"] || source["number"]

    upload =
      case source["document_image"] || source["file"] do
        %Plug.Upload{} = upload -> upload
        _ -> nil
      end

    cond do
      not is_binary(document_type) or
          String.downcase(String.trim(document_type)) not in @document_types ->
        {:error, :invalid_document_type}

      not is_binary(document_number) or String.trim(document_number) == "" ->
        {:error, :invalid_document_number}

      is_nil(upload) ->
        {:error, :missing_document_image}

      true ->
        {:ok,
         %{
           "document_type" => String.downcase(String.trim(document_type)),
           "document_number" => String.trim(document_number),
           "document_image" => upload
         }}
    end
  end

  defp validation_error(conn, changeset) do
    errors = Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{status: "error", message: "Validation failed", errors: errors})
  end
end

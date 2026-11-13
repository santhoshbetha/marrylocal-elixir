defmodule MarrylocalWeb.IdentityVerificationJSON do
  alias Marrylocal.Uploaders.VerificationDocument
  alias MarrylocalWeb.UserJSON

  def data(verification) do
    %{
      id: verification.id,
      user_id: verification.user_id,
      document_type: verification.document_type,
      document_number: verification.document_number,
      identity_hash: verification.identity_hash,
      duplicate_identity_hash_warning:
        Marrylocal.Accounts.Verifications.duplicate_identity_warning?(verification),
      document_image_url: document_url(verification),
      status: verification.status,
      rejection_reason: verification.rejection_reason,
      inserted_at: verification.inserted_at,
      user: verification.user && UserJSON.public_profile(verification.user)
    }
  end

  def owner(verification) do
    %{
      id: verification.id,
      document_type: verification.document_type,
      status: verification.status,
      rejection_reason: verification.rejection_reason,
      inserted_at: verification.inserted_at
    }
  end

  defp document_url(%{document_image: nil}), do: nil
  defp document_url(%{document_image: ""}), do: nil

  defp document_url(%{document_image: image}) do
    case VerificationDocument.presigned_url(image) do
      {:ok, url} -> url
      _ -> nil
    end
  rescue
    _ -> nil
  end
end

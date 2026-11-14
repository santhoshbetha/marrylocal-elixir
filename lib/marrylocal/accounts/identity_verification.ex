defmodule Marrylocal.Accounts.IdentityVerification do
  @moduledoc """
  One identity document submission.

  Every submission creates a permanent row. `document_image` is a Waffle field
  containing the private R2 object key; it is never accepted as a
  client-supplied string. Review decisions stamp `reviewed_by_admin_id` and
  `reviewed_at` so the chronological history survives resubmissions.
  """

  use Ecto.Schema
  use Waffle.Ecto.Schema

  import Ecto.Changeset

  alias Marrylocal.Accounts.User

  @document_types ~w(passport license)
  @statuses ~w(pending_bot_ocr pending_admin_review verified rejected expired)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :id

  schema "identity_verifications" do
    field :document_type, :string
    field :document_number, :string
    field :identity_hash, :string
    field :document_image, Marrylocal.Uploaders.VerificationDocument.Type
    field :status, :string, default: "pending_admin_review"
    field :rejection_reason, :string
    field :submitted_at, :utc_datetime
    field :reviewed_at, :utc_datetime
    field :reviewer_notes, :string

    belongs_to :user, User
    belongs_to :reviewed_by_admin, User

    timestamps(type: :utc_datetime)
  end

  def document_types, do: @document_types
  def statuses, do: @statuses

  def changeset(verification, attrs) do
    verification
    |> cast(attrs, [
      :document_type,
      :document_number,
      :identity_hash,
      :status,
      :rejection_reason,
      :submitted_at,
      :reviewed_at,
      :reviewer_notes,
      :reviewed_by_admin_id
    ])
    |> cast_attachments(attrs, [:document_image])
    |> validate_required([:document_type, :document_number, :document_image])
    |> validate_inclusion(:document_type, @document_types, message: "must be passport or license")
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:document_number, min: 4, max: 60)
    |> unique_constraint(:identity_hash, name: :identity_verifications_active_identity_hash_index)
    |> check_constraint(:document_type, name: :identity_verifications_document_type_check)
    |> check_constraint(:status, name: :identity_verifications_status_check)
  end
end

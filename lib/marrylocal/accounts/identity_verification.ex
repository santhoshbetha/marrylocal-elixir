defmodule Marrylocal.Accounts.IdentityVerification do
  @moduledoc """
  One identity document submitted by a user.

  The row is unique per user. `document_image` is a Waffle field containing the
  private R2 object key; it is never accepted as a client-supplied string.
  """

  use Ecto.Schema
  use Waffle.Ecto.Schema

  import Ecto.Changeset

  alias Marrylocal.Accounts.User

  @document_types ~w(aadhaar passport license)
  @statuses ~w(pending_bot_ocr pending_admin_review verified rejected)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :id

  schema "identity_verifications" do
    field :document_type, :string
    field :document_number, :string
    field :document_image, Marrylocal.Uploaders.VerificationDocument.Type
    field :status, :string, default: "pending_admin_review"
    field :rejection_reason, :string

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def document_types, do: @document_types
  def statuses, do: @statuses

  def changeset(verification, attrs) do
    verification
    |> cast(attrs, [:document_type, :document_number, :status, :rejection_reason])
    |> cast_attachments(attrs, [:document_image])
    |> validate_required([:document_type, :document_number, :document_image])
    |> validate_inclusion(:document_type, @document_types,
      message: "must be aadhaar, passport, or license"
    )
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:document_number, min: 4, max: 60)
    |> unique_constraint(:user_id)
    |> check_constraint(:document_type, name: :identity_verifications_document_type_check)
    |> check_constraint(:status, name: :identity_verifications_status_check)
  end
end

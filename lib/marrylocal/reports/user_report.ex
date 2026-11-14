defmodule Marrylocal.Reports.UserReport do
  @moduledoc """
  One safety report filed by a member against another profile.

  A reporter may have at most one open (`pending`) report per reported member;
  resolved and dismissed rows stay in the table permanently for audit.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Marrylocal.Accounts.User

  @reasons ~w(fake_profile inappropriate_photos harassment married_or_taken scam_or_spam other)
  @statuses ~w(pending reviewed_action_taken dismissed)

  schema "user_reports" do
    field :reason, :string
    field :details, :string
    field :status, :string, default: "pending"
    field :admin_notes, :string
    field :reviewed_at, :utc_datetime

    belongs_to :reporter, User
    belongs_to :reported_user, User
    belongs_to :reviewed_by_admin, User

    timestamps(type: :utc_datetime)
  end

  def reasons, do: @reasons
  def statuses, do: @statuses

  def changeset(report, attrs) do
    report
    |> cast(attrs, [
      :reporter_id,
      :reported_user_id,
      :reason,
      :details,
      :status,
      :admin_notes,
      :reviewed_by_admin_id,
      :reviewed_at
    ])
    |> validate_required([:reporter_id, :reported_user_id, :reason])
    |> validate_inclusion(:reason, @reasons)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:details, max: 1_000)
    |> validate_length(:admin_notes, max: 2_000)
    |> foreign_key_constraint(:reporter_id)
    |> foreign_key_constraint(:reported_user_id)
    |> foreign_key_constraint(:reviewed_by_admin_id)
    |> unique_constraint([:reporter_id, :reported_user_id],
      name: :user_reports_pending_unique_index,
      message: "already has a pending report against this member"
    )
    |> check_constraint(:reporter_id,
      name: :user_reports_no_self,
      message: "cannot be the same member"
    )
    |> check_constraint(:reason, name: :user_reports_reason_allowed)
    |> check_constraint(:status, name: :user_reports_status_allowed)
  end
end

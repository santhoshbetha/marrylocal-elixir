defmodule Marrylocal.Notifications.Notification do
  @moduledoc """
  A single real-time inbox item owned by one user.

  `type` selects the client presentation and `metadata` carries the type-specific
  pointers (sender id, handle, match id, profile shortid). This is the
  polymorphic notification shape proven in MeetCutes: one table, one stream,
  no schema change per new notification kind.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Marrylocal.Accounts.User

  @types [
    :profile_like,
    :mutual_match,
    :profile_shortlist,
    :system,
    :admin_broadcast,
    :verification_update
  ]

  schema "notifications" do
    field :type, Ecto.Enum, values: @types
    field :title, :string
    field :body, :string
    field :is_read, :boolean, default: false
    field :read_at, :utc_datetime
    field :metadata, :map, default: %{}

    belongs_to :user, User
    belongs_to :actor, User

    timestamps(type: :utc_datetime)
  end

  def types, do: @types

  @doc """
  Builds a notification changeset.

  Ownership (`user_id`) and actor (`actor_id`) are assigned by the context, never
  accepted from an HTTP payload.
  """
  def changeset(notification \\ %__MODULE__{}, attrs) do
    notification
    |> cast(attrs, [:type, :title, :body, :is_read, :metadata])
    |> put_change(:user_id, fetch_attr(attrs, :user_id))
    |> put_change(:actor_id, fetch_attr(attrs, :actor_id))
    |> validate_required([:user_id, :type, :title])
    |> validate_length(:title, max: 200)
    |> validate_length(:body, max: 5_000)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:actor_id)
  end

  defp fetch_attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
end

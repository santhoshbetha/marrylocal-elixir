defmodule Marrylocal.Relationships.Relationship do
  @moduledoc """
  One directed profile-discovery state transition.

  A single polymorphic table stores every interaction kind:
  `:like`, `:dislike`, `:shortlist`, `:match`, `:mute`, and `:block`. Keeping
  the kind in a column (rather than separate tables) means discovery can exclude
  every acted-on or hidden profile with indexed subqueries, and mutual matches
  can be recorded atomically alongside the like that completed them.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Marrylocal.Accounts.User

  @kinds [:like, :dislike, :shortlist, :match, :mute, :block]

  schema "relationships" do
    field :kind, Ecto.Enum, values: @kinds
    field :metadata, :map, default: %{}

    belongs_to :actor, User
    belongs_to :target, User

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  @doc """
  Builds a relationship changeset.

  `actor_id` and `target_id` are always assigned by the context from the
  authenticated user and the route target. They are never cast from client
  params, so a caller cannot spoof either side of the interaction.
  """
  def changeset(relationship \\ %__MODULE__{}, attrs) do
    relationship
    |> cast(attrs, [:kind, :metadata])
    |> put_change(:actor_id, fetch_attr(attrs, :actor_id))
    |> put_change(:target_id, fetch_attr(attrs, :target_id))
    |> validate_required([:actor_id, :target_id, :kind])
    |> unique_constraint([:actor_id, :target_id, :kind],
      name: :relationships_actor_id_target_id_kind_index
    )
    |> foreign_key_constraint(:actor_id)
    |> foreign_key_constraint(:target_id)
  end

  defp fetch_attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
end

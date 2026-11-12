defmodule Marrylocal.Accounts.UserPhotoHash do
  @moduledoc "Active SHA-256 fingerprint for a profile photo or avatar."

  use Ecto.Schema
  import Ecto.Changeset

  schema "user_photo_hashes" do
    field :photo_hash, :string
    field :slot_index, :integer
    field :active, :boolean, default: true

    belongs_to :user, Marrylocal.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(hash, attrs) do
    hash
    |> cast(attrs, [:user_id, :photo_hash, :slot_index, :active])
    |> validate_required([:user_id, :photo_hash])
    |> unique_constraint(:photo_hash, name: :user_photo_hashes_active_photo_hash_index)
    |> unique_constraint([:user_id, :slot_index], name: :user_photo_hashes_user_slot_index)
  end
end

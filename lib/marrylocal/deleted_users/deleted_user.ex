defmodule Marrylocal.DeletedUsers.DeletedUser do
  use Ecto.Schema
  schema "deleted_users" do
    field :original_user_id, :integer
    field :email, :string
    field :aadhar_number, :string
    field :data, :map # Stores the full JSON of the user profile
    field :reason, :string, default: "unverified_timeout"

    timestamps()
  end
end

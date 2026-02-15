defmodule Marrylocal.Accounts.Subscription do
  use Ecto.Schema
  import Ecto.Changeset

  schema "subscriptions" do
    field :info, :map
    field :status, :string, default: "pending"
    field :valid_until, :utc_datetime

    belongs_to :user, Marrylocal.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:user_id, :info, :status, :valid_until])
    |> validate_required([:user_id, :status])
    |> foreign_key_constraint(:user_id)
  end
end

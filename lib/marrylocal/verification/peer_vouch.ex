defmodule Marrylocal.Verification.PeerVouch do
  @moduledoc "Audit row for one verified member vouching for another."

  use Ecto.Schema
  import Ecto.Changeset

  alias Marrylocal.Accounts.User

  schema "peer_vouches" do
    field :city, :string

    belongs_to :voucher, User
    belongs_to :vouchee, User

    timestamps(type: :utc_datetime)
  end

  def changeset(vouch, attrs) do
    vouch
    |> cast(attrs, [:voucher_id, :vouchee_id, :city])
    |> validate_required([:voucher_id, :vouchee_id, :city])
    |> foreign_key_constraint(:voucher_id)
    |> foreign_key_constraint(:vouchee_id)
    |> unique_constraint([:voucher_id, :vouchee_id],
      name: :peer_vouches_voucher_id_vouchee_id_index,
      message: "has already vouched for this member"
    )
    |> check_constraint(:voucher_id,
      name: :peer_vouches_no_self,
      message: "cannot vouch for yourself"
    )
  end
end

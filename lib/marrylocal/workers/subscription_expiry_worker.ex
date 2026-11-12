defmodule Marrylocal.Workers.SubscriptionExpiryWorker do
  @moduledoc """
  Daily cleanup for expired monthly location addon entitlements.

  Entitlement checks are already dynamic at read time. This worker removes the
  legacy slot/addon map entries so expired locations disappear from settings
  and old clients as soon as the daily sweep runs.
  """

  use Oban.Worker, queue: :default

  import Ecto.Query

  alias Marrylocal.Accounts.User
  alias Marrylocal.Repo

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    from(u in User,
      where:
        (not is_nil(u.location_2_expires_at) and u.location_2_expires_at <= ^now) or
          (not is_nil(u.location_3_expires_at) and u.location_3_expires_at <= ^now)
    )
    |> Repo.all()
    |> Enum.each(&expire_user/1)

    :ok
  end

  defp expire_user(user) do
    now = DateTime.utc_now()

    slots =
      user.multi_location_slots
      |> drop_expired_slot("location2", user.location_2_expires_at, now)
      |> drop_expired_slot("location3", user.location_3_expires_at, now)

    addons =
      user.addons
      |> drop_expired_slot("location2", user.location_2_expires_at, now)
      |> drop_expired_slot("location3", user.location_3_expires_at, now)

    user
    |> Ecto.Changeset.change(multi_location_slots: slots || %{}, addons: addons || %{})
    |> Repo.update()
  end

  defp drop_expired_slot(nil, _key, _expires_at, _now), do: %{}

  defp drop_expired_slot(map, _key, nil, _now), do: map

  defp drop_expired_slot(map, key, expires_at, now) do
    if DateTime.compare(expires_at, now) != :gt do
      Map.drop(map, [key])
    else
      map
    end
  end
end

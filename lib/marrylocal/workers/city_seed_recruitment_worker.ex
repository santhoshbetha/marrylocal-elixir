defmodule Marrylocal.Workers.CitySeedRecruitmentWorker do
  @moduledoc """
  Keeps up to ten seed-verifier candidates in every city.

  Candidates are active members whose `seed_verifier_status` is `opted_in` or
  `approved`. When a city is short, the next eligible active members are marked
  `invited`, which shows the recruitment banner on the Verify page.

  Args:
    * `%{"city" => city, "state" => state}` - refill one city immediately.
    * `%{}` - refill every city with active members (scheduled sweep).
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query, warn: false

  alias Marrylocal.Accounts.User
  alias Marrylocal.Repo

  @target 10

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    args = args || %{}

    cities =
      if present?(args["city"]) do
        [%{city: args["city"], state: args["state"]}]
      else
        Repo.all(
          from(u in User,
            where: u.user_state == :active and not is_nil(u.city) and u.city != "",
            distinct: true,
            select: %{city: u.city, state: u.state}
          )
        )
      end

    Enum.each(cities, &fill_city/1)
    :ok
  end

  defp fill_city(%{city: city, state: state}) when is_binary(city) and city != "" do
    # Count outstanding invitations as well as accepted candidates so a city
    # never accumulates more than ten parallel invitations. An opt-out frees a
    # slot and the next eligible member is invited.
    pipeline_count =
      User
      |> scope_city(city, state)
      |> where(
        [u],
        u.user_state == :active and
          u.seed_verifier_status in ["invited", "opted_in", "approved"]
      )
      |> Repo.aggregate(:count, :id)

    needed = max(@target - pipeline_count, 0)

    if needed > 0 do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      ids =
        User
        |> scope_city(city, state)
        |> where([u], u.user_state == :active and u.seed_verifier_status == "none")
        |> where([u], u.peer_verified == false and u.is_peer_verifier == false)
        |> order_by(
          [u],
          desc:
            fragment(
              "(CASE WHEN ? IS NULL THEN 0 ELSE 2 END) + (CASE WHEN ? THEN 1 ELSE 0 END) + (CASE WHEN COALESCE(array_length(?, 1), 0) > 0 THEN 1 ELSE 0 END)",
              u.avatar,
              u.core_details_edited,
              u.images
            ),
          asc: u.inserted_at,
          asc: u.id
        )
        |> limit(^needed)
        |> select([u], u.id)
        |> Repo.all()

      if ids != [] do
        from(u in User, where: u.id in ^ids)
        |> Repo.update_all(set: [seed_verifier_status: "invited", updated_at: now])
      end
    end

    :ok
  end

  defp fill_city(_city), do: :ok

  defp scope_city(query, city, state) do
    query
    |> where([u], fragment("lower(?) = lower(?)", u.city, ^city))
    |> maybe_state(state)
  end

  defp maybe_state(query, state) when is_binary(state) and state != "" do
    where(query, [u], fragment("lower(?) = lower(?)", u.state, ^state))
  end

  defp maybe_state(query, _state), do: query

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end

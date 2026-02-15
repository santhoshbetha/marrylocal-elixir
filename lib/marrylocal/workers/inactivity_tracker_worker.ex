defmodule Marrylocal.Workers.InactivityTracker do
  use Oban.Worker, queue: :default
  import Ecto.Query
  alias Marrylocal.{Repo, Accounts.User}

  @impl Oban.Worker
  def perform(_job) do
    # Calculate 6 months ago (approx 180 days)
    six_months_ago = DateTime.utc_now() |> DateTime.add(-180, :day)

    # Query: Active users who haven't logged in for 6 months
    query = from u in User,
      where: u.user_state == :active,
      where: u.time_of_login < ^six_months_ago

    # Perform bulk update
    {count, _} = Repo.update_all(query, set: [user_state: :inactive])

    IO.puts("Marked #{count} users as inactive due to 6-month inactivity.")
    :ok
  end
end

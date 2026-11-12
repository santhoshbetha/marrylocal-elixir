defmodule Marrylocal.Workers.YearlySubscriptionReset do
  @moduledoc """
  Daily Oban job that expires annual service fee access after 365 days.
  """

  use Oban.Worker, queue: :default

  import Ecto.Query

  alias Marrylocal.Accounts.User
  alias Marrylocal.Repo

  @impl Oban.Worker
  def perform(_job) do
    cutoff_date = Date.add(Date.utc_today(), -365)

    cutoff_timestamp =
      DateTime.utc_now() |> DateTime.add(-365, :day) |> DateTime.truncate(:second)

    from(u in User,
      where:
        u.onetime_fees_paid == true and
          ((not is_nil(u.last_payment_at) and u.last_payment_at <= ^cutoff_timestamp) or
             (is_nil(u.last_payment_at) and not is_nil(u.date_of_last_payment) and
                u.date_of_last_payment <= ^cutoff_date))
    )
    |> Repo.update_all(set: [onetime_fees_paid: false, onetime_fees_required: true])

    :ok
  end
end

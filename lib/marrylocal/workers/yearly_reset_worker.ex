defmodule Marrylocal.Workers.YearlyReferralReset do
  use Oban.Worker, queue: :default
  import Ecto.Query
  alias Marrylocal.{Repo, Accounts.User}

  @impl Oban.Worker
  def perform(_job) do
    # Find users whose activation was exactly 1 year ago (or more)
    # but haven't been reset yet this cycle
    one_year_ago = DateTime.utc_now() |> DateTime.add(-365, :day)

    query =
      from u in User,
        where: u.date_of_activation <= ^one_year_ago,
        where: u.onetime_fees_paid == true or fragment("cardinality(referee_emails) > 0")

    # Reset their data
    Repo.update_all(query,
      set: [
        referee_emails: [],
        onetime_fees_paid: false,
        # Update activation date to "now" to restart the 1-year clock
        date_of_activation: DateTime.utc_now()
      ]
    )

    :ok
  end
end

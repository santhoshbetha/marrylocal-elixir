defmodule Marrylocal.Workers.AnniversaryWarning do
  use Oban.Worker, queue: :mailers
  import Ecto.Query
  alias Marrylocal.{Repo, Accounts.User, Mailer}
  alias Marrylocal.Emails.UserEmail

  @impl Oban.Worker
  def perform(_job) do
    # 358 days ago means the 365-day reset is in 7 days
    warning_date = DateTime.utc_now() |> DateTime.add(-358, :day)

    # Find active users hitting their 358-day mark
    query =
      from u in User,
        where: u.date_of_activation <= ^warning_date,
        where: u.user_state == :active

    Repo.all(query)
    |> Enum.each(fn user ->
      UserEmail.anniversary_reminder(user)
      |> Mailer.deliver()
    end)

    :ok
  end
end

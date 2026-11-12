defmodule Marrylocal.Workers.InactivityWarning do
  use Oban.Worker, queue: :mailers
  import Ecto.Query
  alias Marrylocal.{Repo, Accounts.User, Mailer}
  alias Marrylocal.Emails.UserEmail

  @impl Oban.Worker
  def perform(_job) do
    # 177 days ago = 3 days until the 6-month (180 day) cutoff
    warning_threshold = DateTime.utc_now() |> DateTime.add(-177, :day)

    query =
      from u in User,
        where: u.user_state == :active,
        where: u.time_of_login <= ^warning_threshold

    Repo.all(query)
    |> Enum.each(fn user ->
      UserEmail.inactivity_warning(user)
      |> Mailer.deliver()
    end)

    :ok
  end
end

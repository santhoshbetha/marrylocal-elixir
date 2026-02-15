#Reminder Email that triggers 24 hours before an unverified account
#is deleted, you should schedule a one-time Oban job at the moment of registration

#This worker will check if the user is still unverified before
#sending the email to avoid spamming users who have already confirmed.
defmodule Marrylocal.Workers.DeletionReminder do
  use Oban.Worker, queue: :mailers
  alias Marrylocal.{Repo, Accounts.User, UserEmail, Mailer}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    user = Repo.get(User, user_id)

    # Only send if they haven't verified yet
    if user && is_nil(user.confirmed_at) do
      UserEmail.deletion_reminder_email(user)
      |> Mailer.deliver()
    end

    :ok
  end
end

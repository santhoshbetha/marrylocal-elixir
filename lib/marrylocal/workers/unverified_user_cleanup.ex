defmodule Marrylocal.Workers.UnverifiedUserCleanup do
  use Oban.Worker, queue: :default
  import Ecto.Query
  alias Marrylocal.{Repo, Accounts.User}

  @impl Oban.Worker
  def perform(_job) do
    one_week_ago = DateTime.utc_now() |> DateTime.add(-7, :day)

    # Find unverified users older than 7 days
    expired_users_query = from u in User,
      where: is_nil(u.confirmed_at) and u.inserted_at < ^one_week_ago

    expired_users = Repo.all(expired_users_query)

    Enum.each(expired_users, fn user ->
      Repo.transaction(fn ->
        # 1. Archive to deleted_users table
        Repo.insert_all("deleted_users", [%{
          email: user.email,
          aadhar_number: user.aadhar_number,
          data: Map.from_struct(user) |> Map.delete(:__meta__),
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }])

        # 2. Schedule the R2 folder deletion
        # We use a separate worker so S3 failures don't block the DB transaction
        %{shortid: user.shortid}
        |> Marrylocal.Workers.R2Cleanup.new()
        |> Oban.insert()

        # 3. Permanent delete from users table
        Repo.delete!(user)
      end)
    end)

    :ok
  end
end

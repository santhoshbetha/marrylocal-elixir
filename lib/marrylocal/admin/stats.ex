defmodule Marrylocal.Admin.Stats do
  import Ecto.Query
  alias Marrylocal.{Repo, Accounts.User}

  def get_dashboard_counts do
    today = Date.utc_today()

    # 1. Total Active Users
    total_users = Repo.aggregate(from(u in User, where: u.user_state == :active), :count, :id)

    # 2. Today's Joins (Created Today)
    today_joins = Repo.aggregate(
      from(u in User, where: fragment("?::date", u.date_of_creation) == ^today),
      :count, :id
    )

    # 3. Pending Verifications (Unverified Aadhar or Email)
    pending_verifications = Repo.aggregate(
      from(u in User, where: u.aadhar_verified == false or u.email_verified == false),
      :count, :id
    )

    # 4. Archived/Deleted Users count
    archived_count = Repo.aggregate(Marrylocal.DeletedUser, :count, :id)

    %{
      total_users: total_users,
      today_joins: today_joins,
      pending_verifications: pending_verifications,
      archived_count: archived_count
    }
  end
end

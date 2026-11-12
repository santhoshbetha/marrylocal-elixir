defmodule Marrylocal.Admin do
  alias Ecto.Multi
  alias Marrylocal.{Repo, Accounts.User}
  alias Marrylocal.DeletedUsers.DeletedUser
  alias Marrylocal.{Repo, Accounts.Subscription}

  def ban_user(admin, target_user, reason \\ "Banned by Admin") do
    Multi.new()
    # 1. Update status to 'deleted'
    |> Multi.update(:status_update, User.changeset(target_user, %{user_state: :deleted}))

    # 2. Archive to deleted_users table
    |> Multi.insert(:archive, %DeletedUser{
      original_user_id: target_user.id,
      email: target_user.email,
      aadhar_number: target_user.aadhar_number,
      # Store the full struct as a map, plus who banned them
      data:
        Map.from_struct(target_user)
        |> Map.delete(:__meta__)
        |> Map.put(:banned_by_admin_id, admin.id),
      reason: reason
    })

    # 3. Schedule R2 Image Cleanup (The Oban worker we built earlier)
    |> Multi.insert(:cleanup_job, fn _ ->
      Marrylocal.Workers.R2Cleanup.new(%{shortid: target_user.shortid})
    end)

    # 4. Clear sensitive arrays in the main table
    |> Multi.update(:clear_data, User.changeset(target_user, %{images: [], shortlist: []}))
    |> Repo.transaction()
  end

  # create a method to grant or update subscriptions.
  def grant_subscription(user_id, plan_name, duration_days) do
    expiry = DateTime.utc_now() |> DateTime.add(duration_days * 24 * 60 * 60)

    %Subscription{}
    |> Subscription.changeset(%{
      user_id: user_id,
      status: "active",
      valid_until: expiry,
      info: %{
        "plan" => plan_name,
        "granted_by_admin" => true,
        "features" => ["unlimited_search", "see_contact_info"]
      }
    })
    |> Repo.insert(on_conflict: :replace_all, conflict_target: :user_id)
  end
end

defmodule MarrylocalWeb.Plugs.TrackUserActivity do
  alias Marrylocal.Repo
  alias Marrylocal.Accounts.User
  import Ecto.Query

  def init(opts), do: opts

  def call(conn, _opts) do
    # Only update if a user is logged in
    case conn.assigns[:current_user] do
      %User{id: user_id, user_state: state} ->
        Task.start(fn ->
          # If user was inactive, make them active again on login/activity
          new_state = if state == :inactive, do: :active, else: state

          from(u in User, where: u.id == ^user_id)
          |> Repo.update_all(set: [
            time_of_login: DateTime.utc_now(),
            user_state: new_state
          ])
        end)
        conn
      _ -> conn
    end
  end
end

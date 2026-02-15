defmodule MarrylocalWeb.ApiAuth do
  import Plug.Conn
  alias Marrylocal.Accounts

  # 1 day in seconds
  @max_age 86_400

  def init(opts), do: opts

  def fetch_api_user(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, _user_id} <- Phoenix.Token.verify(conn, "user auth", token, max_age: @max_age),
          # 2. Lookup user by the session token in DB
         user when not is_nil(user) <- Accounts.get_user_by_session_token(token) do
      assign(conn, :current_user, user)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "Invalid or expired token"})
        |> halt()
    end
  end
end

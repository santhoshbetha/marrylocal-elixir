defmodule MarrylocalWeb.SessionController do
  use MarrylocalWeb, :controller

  alias Marrylocal.Accounts

  # magic link login
  # 1. Magic Link Login (Verifying the token)
  def create(conn, %{"user" => %{"token" => token}}) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, _expired_tokens}} ->
        # We generate an API token for the client to store
        api_token = Phoenix.Token.sign(conn, "user auth", user.id)

        conn
        |> put_status(:ok)
        |> json(%{
          data: %{token: api_token},
          message: "Welcome back!"
        })

      {:error, :not_found} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "The link is invalid or it has expired."})
    end
  end

  # email + password login
  def create(conn, %{"user" => %{"email" => email, "password" => password}}) do
    if user = Accounts.get_user_by_email_and_password(email, password) do
      # Generate a random token and save it to `users_tokens` table
      token = Accounts.generate_user_session_token(user)

      conn
      |> put_status(:ok)
      |> json(%{
        data: %{
          token: Base.url_encode64(token, padding: false), # Encode for the header
          email: user.email
        }
      })
    else
      # 2. Return a 422 Unprocessable Entity
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{errors: "Invalid email or password"})
    end
  end

  # magic link request
  def create(conn, %{"email" => email}) do
    if user = Accounts.get_user_by_email(email) do
      # Note: Update your mailer URL to point to your frontend URL, not the Phoenix URL
      Accounts.deliver_login_instructions(user, &"https://marrylocal.in#{&1}")
    end

    conn
    |> put_status(:accepted)
    |> json(%{message: "If your email is in our system, you will receive instructions shortly."})
  end

  # 4. Delete (Logout)
  def delete(conn, _params) do
    # 1. Extract the token from the Bearer header
    with ["Bearer " <> token] <- get_req_header(conn, "authorization") do
      # 2. Delete the token from the database
      Accounts.delete_user_session_token(token)

      conn
      |> put_status(:ok)
      |> json(%{message: "Logged out successfully. Token revoked."})
    else
      _ ->
        # If no token provided, just return 200/204 anyway
        send_resp(conn, :no_content, "")
    end
  end
end

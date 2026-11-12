defmodule MarrylocalWeb.SessionController do
  @moduledoc """
  Stateless JSON login handshake.

  A successful password or magic-link login returns an opaque database-backed
  bearer token. Nothing about the session is stored in cookies or node-local
  state, so the React client can send `Authorization: Bearer <token>` to any
  backend node.
  """

  use MarrylocalWeb, :controller

  alias Marrylocal.Accounts
  alias Marrylocal.Accounts.User
  alias MarrylocalWeb.UserJSON

  @handle_pattern ~r/^[a-z][a-z0-9_]{4,14}$/

  @doc """
  GET /api/v1/auth/check-handle?handle=@name

  Public, case-insensitive availability probe. Leading `@` characters are
  stripped before the check so both `name` and `@name` resolve identically.
  """
  def check_handle(conn, %{"handle" => handle}) when is_binary(handle) do
    clean_handle =
      handle
      |> String.trim()
      |> String.trim_leading("@")
      |> String.downcase()

    cond do
      clean_handle == "" ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{available: false, message: "Enter a handle to check."})

      not Regex.match?(@handle_pattern, clean_handle) ->
        json(conn, %{
          available: false,
          message:
            "Handles must be 5-15 characters, start with a letter, and use only letters, numbers, or underscores."
        })

      Accounts.handle_taken?(clean_handle) ->
        json(conn, %{available: false, message: "This handle is already taken."})

      true ->
        json(conn, %{available: true, message: "Handle is available!"})
    end
  end

  def check_handle(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{available: false, message: "Enter a handle to check."})
  end

  @doc "PUT /api/v1/auth/password (authenticated)"
  def update_password(conn, %{"user" => params}) do
    user = conn.assigns.current_user
    current_password = params["current_password"]

    cond do
      not is_binary(current_password) or current_password == "" ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          status: "error",
          code: "current_password_required",
          message: "Enter your current password."
        })

      not User.valid_password?(user, current_password) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          status: "error",
          code: "invalid_current_password",
          message: "Your current password is incorrect."
        })

      true ->
        case Accounts.update_user_password(user, %{
               password: params["password"],
               password_confirmation: params["password_confirmation"]
             }) do
          {:ok, {updated, _expired_tokens}} ->
            token = Accounts.generate_user_session_token(updated)

            conn
            |> put_status(:ok)
            |> json(%{
              status: "success",
              message: "Password updated successfully.",
              data: %{
                token: token,
                token_type: "Bearer",
                user: UserJSON.auth(updated)
              }
            })

          {:error, changeset} ->
            errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)

            conn
            |> put_status(:unprocessable_entity)
            |> json(%{
              status: "error",
              code: "invalid_password",
              message: "Password could not be updated.",
              errors: errors
            })
        end
    end
  end

  def update_password(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      status: "error",
      code: "missing_password_params",
      message: "Enter your current and new password."
    })
  end

  # Magic link login (verifying the emailed token)
  def create(conn, %{"user" => %{"token" => token}}) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, _expired_tokens}} ->
        user = user |> Accounts.record_login() |> Accounts.refresh_gating()
        api_token = Accounts.generate_user_session_token(user)

        conn
        |> put_status(:ok)
        |> json(%{
          status: "success",
          data: %{token: api_token, user: MarrylocalWeb.UserJSON.auth(user)},
          message: "Welcome back!"
        })

      {:error, :not_found} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{
          status: "error",
          message: "The link is invalid or it has expired."
        })
    end
  end

  # Email + password login
  def create(conn, %{"user" => %{"email" => email, "password" => password}}) do
    if user = Accounts.get_user_by_email_and_password(email, password) do
      user = user |> Accounts.record_login() |> Accounts.refresh_gating()
      token = Accounts.generate_user_session_token(user)

      conn
      |> put_status(:ok)
      |> json(%{
        status: "success",
        data: %{
          token: token,
          token_type: "Bearer",
          expires_in_days: 14,
          user: MarrylocalWeb.UserJSON.auth(user)
        }
      })
    else
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{status: "error", message: "Invalid email or password"})
    end
  end

  # Magic link request
  def create(conn, %{"email" => email}) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(user, &"#{Accounts.frontend_url()}#{&1}")
    end

    conn
    |> put_status(:accepted)
    |> json(%{
      status: "success",
      message: "If your email is in our system, you will receive instructions shortly."
    })
  end

  # Logout (token revocation)
  def delete(conn, _params) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization") do
      Accounts.delete_user_session_token(token)

      conn
      |> put_status(:ok)
      |> json(%{status: "success", message: "Logged out successfully. Token revoked."})
    else
      _ ->
        send_resp(conn, :no_content, "")
    end
  end
end

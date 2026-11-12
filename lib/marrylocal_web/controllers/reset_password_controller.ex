defmodule MarrylocalWeb.ResetPasswordController do
  use MarrylocalWeb, :controller

  require Logger

  alias Marrylocal.Accounts
  alias Marrylocal.RateLimit

  # 2 hours in milliseconds.
  @two_hours 7_200_000
  # Allow only 2 attempts every 2 hours per email/IP.
  @max_attempts 2

  @generic_message "If an account exists with this email, instructions have been sent."

  @doc """
  `POST /api/v1/auth/forgot-password`

  Always responds `200 OK` for a valid request, whether or not the email belongs
  to an account, so the endpoint cannot be used for account enumeration.
  """
  def create(conn, %{"email" => email} = params) do
    email = normalize_email(email)

    if honeypot_filled?(params) do
      # Bots receive the same response as humans, but no email is dispatched.
      render_success(conn)
    else
      with {:allow, _} <- RateLimit.check(ip_key(conn), @max_attempts, @two_hours),
           {:allow, _} <- RateLimit.check(email_key(email), @max_attempts, @two_hours) do
        RateLimit.hit(ip_key(conn), @two_hours, @max_attempts)
        RateLimit.hit(email_key(email), @two_hours, @max_attempts)

        send_reset_instructions(conn, email)
      else
        {:deny, _} ->
          conn
          |> put_status(:too_many_requests)
          |> json(%{
            error: "too_many_requests",
            message:
              "To reduce spam, you can only request 2 reset links every 2 hours. Please try again later."
          })
      end
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_request", message: "An email address is required."})
  end

  @doc """
  `POST /api/v1/auth/reset-password` and
  `PUT /api/v1/auth/reset-password/:token` (React client compatibility).

  The token may arrive in the path, or in the request body as `token`.
  Password attributes may be nested under `user` or sent at the top level.
  """
  def update(conn, params) do
    token = params["token"] || params["reset_token"]

    with token when is_binary(token) and token != "" <- token,
         {:ok, user} <- Accounts.get_user_by_reset_password_token(token),
         {:ok, _user} <- Accounts.reset_user_password(user, password_params(params)) do
      json(conn, %{message: "Password reset successfully."})
    else
      :error ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Reset link is invalid or has expired."})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)})

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: "A reset token is required."})
    end
  end

  defp send_reset_instructions(conn, email) do
    case Accounts.get_user_by_email(email) do
      nil ->
        # Silent success: never reveal that the address is not registered.
        render_success(conn)

      user ->
        reset_url_fun = fn token ->
          "#{Accounts.frontend_url()}/reset-password?token=#{URI.encode_www_form(token)}"
        end

        case Accounts.deliver_user_reset_password_instructions(user, reset_url_fun) do
          {:ok, _email} ->
            render_success(conn)

          {:error, :already_sent_recently} ->
            # A link was sent moments ago; keep the response identical.
            render_success(conn)

          {:error, reason} ->
            # Log server-side, but still return 200 so a delivery failure cannot
            # be used to probe which addresses exist.
            Logger.error("Password reset email delivery failed: #{inspect(reason)}")
            render_success(conn)
        end
    end
  end

  defp render_success(conn) do
    conn
    |> put_status(:ok)
    |> json(%{message: @generic_message})
  end

  defp password_params(%{"user" => %{} = user}) do
    Map.take(user, ["password", "password_confirmation"])
  end

  defp password_params(params) do
    Map.take(params, ["password", "password_confirmation"])
  end

  defp honeypot_filled?(params) do
    case params["nickname"] do
      nickname when is_binary(nickname) -> String.trim(nickname) != ""
      _ -> false
    end
  end

  defp normalize_email(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end

  defp normalize_email(_email), do: ""

  defp ip_key(conn), do: "reset_ip:#{peer_ip(conn)}"
  defp email_key(email), do: "reset_email:#{email}"

  defp peer_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end

  defp translate_error({msg, opts}) do
    Gettext.dgettext(MarrylocalWeb.Gettext, "errors", msg, opts)
  end
end

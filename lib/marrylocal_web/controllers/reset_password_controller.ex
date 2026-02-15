defmodule MarrylocalWeb.ResetPasswordController do
  use MarrylocalWeb, :controller
  alias Marrylocal.Accounts

  alias Marrylocal.RateLimit

  # 2 Hours in milliseconds
  @two_hours 7_200_000
  # Allow only 2 attempts every 2 hours per Email/IP
  @max_attempts 2

  # Example: 3 requests per 5 minutes per IP address
  # Config: Max 3 requests per 10 minutes
  @scale :timer.minutes(5)
  @limit 3

  # STEP 1: User submits email to get a reset link
  def createX(conn, %{"email" => email}) do
    ip_key = "ip_limit:#{peer_ip(conn)}"
    email_key = "email_limit:#{email}"

    with {:allow, _} <- RateLimit.check(ip_key, @scale, @limit),
         {:allow, _} <- RateLimit.check(email_key, @scale, @limit) do

      # If both are allowed, record the "hit" for both
      RateLimit.hit(ip_key, @scale, @limit)
      RateLimit.hit(email_key, @scale, @limit)

      # Proceed with sending email
      send_reset_instructions(conn, email)
    else
      {:deny, _} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "Too many requests. Please try again later."})
    end
  end

  #Dual Rate Limiting with Hammer
  # The most effective way is to limit requests by both IP address (to stop bot attacks)
  # and Email address (to stop targeted spamming of a single inbox)
  def create(conn, %{"email" => email}) do
    ip_key = "reset_ip:#{peer_ip(conn)}"
    email_key = "reset_email:#{email}"

    # Check both keys against the 2-hour limit
    with {:allow, _} <- RateLimit.check(ip_key, @two_hours, @max_attempts),
         {:allow, _} <- RateLimit.check(email_key, @two_hours, @max_attempts) do

      # Record the hits
      RateLimit.hit(ip_key, @two_hours, @max_attempts)
      RateLimit.hit(email_key, @two_hours, @max_attempts)

      # Your existing logic to send email
      send_reset_instructions(conn, email)
    else
      {:deny, _limit} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{
          error: "too_many_requests",
          message: "To reduce spam, you can only request 2 reset links every 2 hours. Please try again later."
        })
    end
  end

  #HoneyPot
  # In your UserResetPasswordController, check if this field has any value. If a bot fills it in,
  # you pretend the request was successful but do not send an email.
  def create(conn, %{"email" => email, "nickname" => nickname}) do
    # 1. BOT TRAP: If the hidden 'nickname' field is filled, it's a bot.
    if nickname != "" do
      # Return a 200 OK so the bot thinks it succeeded, but skip the email.
      conn
      |> put_status(:ok)
      |> json(%{message: "If an account exists, instructions have been sent."})
    else
      # 2. HUMAN FLOW: Proceed with your 2-hour Hammer rate limit
      process_human_request(conn, email)
    end
  end

  # internal function called by your create action once the Honeypot check passes.
  defp process_human_request(conn, email) do
    case Accounts.get_user_by_email(email) do
      nil ->
        # Silent Success: Don't reveal the email doesn't exist
        render_silent_success(conn)

      _user ->
        # Check if we sent an email too recently (Database Cooldown)
        # ... rest of the logic
        # For now, just send
        send_reset_instructions(conn, email)
    end
  end

  defp send_reset_instructions(conn, email) do
    # 1. Try to find the user
    case Accounts.get_user_by_email(email) do
      nil ->
        # SILENT SUCCESS: Don't let hackers know if the email exists
        render_success(conn)

      user ->
        # 2. Call the context to generate token and send email
        case Accounts.deliver_user_reset_password_instructions(user, &~p"/users/reset_password/#{&1}") do
          {:ok, _} ->
            render_success(conn)

          {:error, :already_sent_recently} ->
            # We skipped the email cost because one was sent < 15 mins ago
            # But we still tell the user "Success" so they don't panic
            render_success(conn)

          _ ->
            conn |> put_status(500) |> json(%{error: "Service unavailable"})
        end
    end
  end

  defp render_success(conn) do
    conn
    |> put_status(:ok)
    |> json(%{message: "If an account exists with this email, instructions have been sent."})
  end

  # STEP 2: User submits the new password with the token from the email
  def update(conn, %{"token" => token, "user" => user_params}) do
    case Accounts.get_user_by_reset_password_token(token) do
      {:ok, user} ->
        case Accounts.reset_user_password(user, user_params) do
          {:ok, _} ->
            json(conn, %{message: "Password reset successfully."})

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)})
        end

      :error ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Reset link is invalid or has expired."})
    end
  end

  defp render_silent_success(conn) do
    conn
    |> put_status(:ok)
    |> json(%{message: "If an account exists, instructions have been sent to your email."})
  end


  defp peer_ip(conn) do
    conn.remote_ip |> Tuple.to_list() |> Enum.join(".")
  end

  defp translate_error({msg, opts}) do
    Gettext.dgettext(MarrylocalWeb.Gettext, "errors", msg, opts)
  end
end

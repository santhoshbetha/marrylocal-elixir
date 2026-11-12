defmodule MarrylocalWeb.EmailVerificationController do
  @moduledoc """
  JSON email-verification handshake.

  Confirmation tokens are opaque, single-use, and database-backed. A successful
  verification confirms the account, revokes any older session, and returns a
  fresh bearer token so the client can move straight into profile setup.
  """

  use MarrylocalWeb, :controller

  alias Marrylocal.Accounts
  alias Marrylocal.Accounts.User

  @doc """
  Verifies an email confirmation token.

  Accepts either `%{"token" => token}` or `%{"user" => %{"token" => token}}`.
  """
  def create(conn, params) do
    case token_from(params) do
      token when is_binary(token) and token != "" ->
        verify(conn, token)

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{status: "error", message: "Verification token is required."})
    end
  end

  @doc """
  Requests a fresh confirmation email.

  The response is intentionally identical for unknown, already-confirmed, and
  pending accounts so the endpoint cannot be used to enumerate users.
  """
  def resend(conn, params) do
    case email_from(params) do
      email when is_binary(email) and email != "" ->
        email
        |> String.trim()
        |> String.downcase()
        |> Accounts.get_user_by_email()
        |> deliver_confirmation()

      _ ->
        :ok
    end

    conn
    |> put_status(:accepted)
    |> json(%{
      status: "success",
      message: "If this address still needs verification, a fresh link is on its way."
    })
  end

  defp verify(conn, token) do
    case Accounts.confirm_user_by_token(token) do
      {:ok, user} ->
        user = Accounts.record_login(user)
        api_token = Accounts.generate_user_session_token(user)

        conn
        |> put_status(:ok)
        |> json(%{
          status: "success",
          message: "Email verified successfully.",
          data: %{
            token: api_token,
            token_type: "Bearer",
            expires_in_days: 14,
            user: MarrylocalWeb.UserJSON.auth(user)
          }
        })

      {:error, :not_found} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          status: "error",
          message: "This verification link is invalid or has expired."
        })

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", message: "We could not verify this email address."})
    end
  end

  defp deliver_confirmation(%User{confirmed_at: nil} = user) do
    _ = Accounts.deliver_confirmation_instructions(user, &Accounts.confirmation_url/1)
    :ok
  rescue
    error ->
      require Logger
      Logger.error("Could not resend confirmation email: #{inspect(error)}")
      :ok
  end

  defp deliver_confirmation(_user), do: :ok

  defp token_from(%{"token" => token}) when is_binary(token), do: String.trim(token)

  defp token_from(%{"user" => %{"token" => token}}) when is_binary(token),
    do: String.trim(token)

  defp token_from(_params), do: nil

  defp email_from(%{"email" => email}) when is_binary(email), do: email
  defp email_from(%{"user" => %{"email" => email}}) when is_binary(email), do: email
  defp email_from(_params), do: nil
end

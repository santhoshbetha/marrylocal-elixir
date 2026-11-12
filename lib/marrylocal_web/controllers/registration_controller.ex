defmodule MarrylocalWeb.RegistrationController do
  @moduledoc """
  JSON registration handshake.

  Accepts either a flat payload or `%{"user" => ...}`. On success the caller gets
  the same opaque bearer token shape as login, so onboarding can continue
  without a second round-trip.
  """

  use MarrylocalWeb, :controller

  alias Marrylocal.Accounts

  def create(conn, %{"user" => user_params}), do: register(conn, user_params)
  def create(conn, params), do: register(conn, params)

  defp register(conn, user_params) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        # Email delivery is best-effort; a mail outage must not roll back a
        # successfully created account.
        _ =
          Accounts.deliver_confirmation_instructions(
            user,
            &Accounts.confirmation_url/1
          )

        token = Accounts.generate_user_session_token(user)

        conn
        |> put_status(:created)
        |> json(%{
          status: "success",
          message:
            "Account created. Check your email to confirm, or continue with the returned session token.",
          data: %{
            token: token,
            token_type: "Bearer",
            user: MarrylocalWeb.UserJSON.auth(user)
          }
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
            Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
              opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
            end)
          end)

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", message: "Registration failed", errors: errors})

      {:error, :invalid_referral_code} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          status: "error",
          code: "invalid_referral_code",
          message: "The referral code is invalid."
        })

      {:error, :self_referral_not_allowed} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          status: "error",
          code: "self_referral_not_allowed",
          message: "You cannot use your own referral code."
        })

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", message: "Registration failed: #{inspect(reason)}"})
    end
  end
end

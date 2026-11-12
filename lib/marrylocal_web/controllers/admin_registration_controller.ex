defmodule MarrylocalWeb.AdminRegistrationController do
  @moduledoc """
  Public administrative registration handshake.

  The invite code is compared against `ADMIN_INVITE_CODE` with
  `Plug.Crypto.secure_compare/2` before any account work happens. A valid code
  creates an unverified admin with a persisted integer age (the raw birth date
  stays virtual) and emails the normal confirmation link.
  """

  use MarrylocalWeb, :controller

  require Logger

  alias Marrylocal.Accounts
  alias Marrylocal.Accounts.User

  def create(conn, params) do
    attrs =
      case params["admin"] do
        %{} = admin_params -> admin_params
        _ -> params
      end

    if User.admin_invite_code_valid?(attrs["invite_code"]) do
      case Accounts.register_admin(attrs) do
        {:ok, admin} ->
          _ = deliver_confirmation(admin)

          conn
          |> put_status(:created)
          |> json(%{
            status: "success",
            message:
              "Admin account created. Check your email to verify the address before signing in.",
            data: %{user: MarrylocalWeb.UserJSON.auth(admin)}
          })

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{
            status: "error",
            message: "Admin registration failed",
            errors: traverse_errors(changeset)
          })
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{
        status: "error",
        code: "invalid_invite_code",
        message: "The admin invite code is invalid."
      })
    end
  end

  # Email delivery is best-effort: a mail outage must not roll back an account
  # that has already been persisted.
  defp deliver_confirmation(admin) do
    Accounts.deliver_confirmation_instructions(admin, &Accounts.confirmation_url/1)
  rescue
    error ->
      Logger.error("Could not send admin confirmation email: #{Exception.message(error)}")
      {:error, error}
  end

  defp traverse_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end

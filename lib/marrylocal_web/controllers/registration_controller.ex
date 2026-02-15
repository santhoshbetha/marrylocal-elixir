defmodule MarrylocalWeb.RegistrationController do
  use MarrylocalWeb, :controller

  alias Marrylocal.Accounts

  def create(conn, %{"user" => user_params}) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        # Send magic link / confirmation email
        # Update the URL to point to your Frontend/Mobile app link handler
        {:ok, _} =
          Accounts.deliver_login_instructions(
            user,
            &"https://marrylocal.in#{&1}"
          )

        conn
        |> put_status(:created)
        |> json(%{
          message: "User created successfully. Please check your email to confirm your account.",
          email: user.email
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        # Use a helper to translate changeset errors into a readable JSON map
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
          Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
            opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
          end)
        end)

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors})
    end
  end
end

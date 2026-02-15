defmodule MarrylocalWeb.SettingsController do
  use MarrylocalWeb, :controller
  alias Marrylocal.Accounts

  import MarrylocalWeb.UserAuth, only: [require_sudo_mode: 2]

  plug :require_sudo_mode
  #plug :assign_email_and_password_changesets

  # 1. Update Email
  def update(conn, %{"action" => "update_email", "user" => user_params}) do
    user = conn.assigns.current_user

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        # Generate confirmation link pointing to your Frontend
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &"https://marrylocal.in#{&1}"
        )

        conn
        |> put_status(:accepted)
        |> json(%{message: "A confirmation link has been sent to your new email address."})

      changeset ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  # 2. Update Password
  def update(conn, %{"action" => "update_password", "user" => user_params}) do
    user = conn.assigns.current_user

    case Accounts.update_user_password(user, user_params) do
      {:ok, {_user, _}} ->
        # In an API, we don't 're-log in' with cookies;
        # we just confirm success or provide a new token if rotating.
        conn
        |> put_status(:ok)
        |> json(%{message: "Password updated successfully."})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  # 3. Confirm Email Change
  def confirm_email(conn, %{"token" => token}) do
    case Accounts.update_user_email(conn.assigns.current_user, token) do
      {:ok, _user} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Email changed successfully."})

      {:error, _} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Email change link is invalid or it has expired."})
    end
  end

  # Helper to translate Ecto errors to JSON
  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

end

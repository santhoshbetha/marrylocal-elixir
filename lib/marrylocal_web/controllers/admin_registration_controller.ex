defmodule MarrylocalWeb.AdminRegistrationController do
  use MarrylocalWeb, :controller
  alias Marrylocal.Accounts

  def create(conn, %{"admin" => admin_params}) do
    case Accounts.register_admin(admin_params) do
      {:ok, admin} ->
        # Issue a session token immediately
        token = Accounts.create_user_session_token(admin)

        conn
        |> put_status(:created)
        |> json(%{
          message: "Admin account created successfully",
          token: Base.url_encode64(token, padding: false),
          role: admin.role
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)})
    end
  end

  defp translate_error({msg, opts}) do
    Gettext.dgettext(MarrylocalWeb.Gettext, "errors", msg, opts)
  end
end

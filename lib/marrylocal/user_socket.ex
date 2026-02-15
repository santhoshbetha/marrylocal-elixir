defmodule MarrylocalWeb.UserSocket do
  use Phoenix.Socket
  alias Marrylocal.Accounts

  # This connects the React client to the Elixir process
  def connect(%{"token" => token}, socket, _connect_info) do
    case Accounts.get_user_by_session_token(token) do
      {:ok, user} ->
        {:ok, assign(socket, :user_id, user.id)}
      _ ->
        :error
    end
  end

  def id(socket), do: "users_socket:#{socket.assigns.user_id}"
end

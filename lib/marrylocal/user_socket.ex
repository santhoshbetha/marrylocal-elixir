defmodule MarrylocalWeb.UserSocket do
  use Phoenix.Socket

  alias Marrylocal.Accounts

  # Every channel is scoped to the bearer user. Notifications use
  # `user_notifications:<user_id>` as specified by the API contract.
  channel "user_notifications:*", MarrylocalWeb.UserChannel
  channel "notifications:*", MarrylocalWeb.UserChannel

  @doc """
  Authenticates the WebSocket with the same opaque bearer token used by HTTP.

  The token is verified against the database on connect, then the user id and
  struct are assigned for channel authorization.
  """
  def connect(%{"token" => token}, socket, _connect_info) do
    case Accounts.get_user_by_session_token(token) do
      {%Marrylocal.Accounts.User{} = user, _inserted_at} ->
        Accounts.touch_last_seen(user)

        socket =
          socket
          |> assign(:current_user, user)
          |> assign(:current_user_id, user.id)

        {:ok, socket}

      _ ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  def id(socket), do: "user_socket:#{socket.assigns.current_user_id}"
end

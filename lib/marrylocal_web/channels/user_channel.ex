defmodule MarrylocalWeb.UserChannel do
  @moduledoc """
  Live notification and presence stream for one authenticated user.

  Clients join `user_notifications:<user_id>`. The topic id must match the
  bearer user that authenticated the socket, otherwise the join is rejected.
  Every notification is scoped to a single user topic; presence state is
  tracked on the shared `presence` topic and pushed back through this private
  channel. Peer-verification changes are broadcast on the same user topic as
  `peer_verification_updated` and delivered automatically by the channel
  server, so the Verification page does not need to poll.
  """

  use MarrylocalWeb, :channel

  require Logger

  alias Marrylocal.Accounts
  alias MarrylocalWeb.Presence

  @impl true
  def join("user_notifications:" <> user_id, _payload, socket) do
    if to_string(socket.assigns.current_user_id) == user_id do
      case Accounts.get_user(socket.assigns.current_user_id) do
        nil ->
          {:error, %{reason: "user_not_found"}}

        user ->
          Logger.metadata(user_id: user_id)
          Phoenix.PubSub.subscribe(Marrylocal.PubSub, Presence.topic())
          send(self(), :after_presence_join)

          {:ok,
           socket
           |> assign(:notification_user_id, user_id)
           |> assign(:presence_last_login, user.last_login_at || user.time_of_login)}
      end
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info(:after_presence_join, socket) do
    user = socket.assigns.current_user

    {:ok, _ref} =
      Presence.track(self(), Presence.topic(), "user:#{user.id}", %{
        user_id: user.id,
        first_name: user.first_name,
        user_handle: user.user_handle,
        online_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        last_login: format_datetime(socket.assigns.presence_last_login)
      })

    push(socket, "presence_state", Presence.list(Presence.topic()))
    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{event: "presence_diff", payload: diff},
        socket
      ) do
    push(socket, "presence_diff", diff)
    {:noreply, socket}
  end

  @impl true
  def handle_in("ping", payload, socket) do
    {:reply, {:ok, payload}, socket}
  end

  @impl true
  def handle_in("subscribe", _payload, socket) do
    {:reply, {:ok, %{subscribed: true}}, socket}
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_datetime(value) when is_binary(value), do: value
end

defmodule MarrylocalWeb.PeerVerificationNotifier do
  @moduledoc """
  Pushes peer-verification state changes to the member's private channel topic.

  Browsers join `user_notifications:<user_id>` (the same topic used for in-app
  notifications), so a successful vouch or an administrative grant updates the
  Verification page immediately instead of polling the profile endpoint.
  """

  alias MarrylocalWeb.Endpoint

  @event "peer_verification_updated"
  @topic_prefix "user_notifications:"

  @doc "Broadcasts the resulting state to the member who was vouched for."
  def vouch_recorded(result) do
    broadcast(result.vouchee.id, %{
      reason: "vouch",
      peer_vouches_received: result.current_vouches,
      peer_verified: result.peer_verified,
      vouch_credits_remaining: result.vouch_credits_remaining
    })
  end

  @doc "Broadcasts granted peer-verifier state to each updated member."
  def grants_applied(users) when is_list(users) do
    Enum.each(users, fn user ->
      broadcast(user.id, %{
        reason: "admin_grant",
        peer_vouches_received: user.peer_vouches_received,
        peer_verified: user.peer_verified,
        vouch_credits_remaining: user.vouch_credits_remaining
      })
    end)
  end

  defp broadcast(user_id, payload) do
    Endpoint.broadcast("#{@topic_prefix}#{user_id}", @event, payload)
  end
end

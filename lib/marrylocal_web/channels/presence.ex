defmodule MarrylocalWeb.Presence do
  @moduledoc """
  Cluster-aware online presence for authenticated MarryLocal members.

  Presence keys use the `user:<id>` shape so the same map can be consumed by
  HTTP serializers and the React presence store without exposing raw account
  data.
  """

  use Phoenix.Presence,
    otp_app: :marrylocal,
    pubsub_server: Marrylocal.PubSub

  @topic "presence"

  def topic, do: @topic

  def online_user_ids do
    @topic
    |> list()
    |> Map.keys()
    |> Enum.map(&parse_user_key/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  def online?(user_id) when is_integer(user_id) do
    MapSet.member?(online_user_ids(), user_id)
  end

  def online?(_user_id), do: false

  defp parse_user_key("user:" <> id), do: parse_int(id)
  defp parse_user_key(id), do: parse_int(id)

  defp parse_int(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> nil
    end
  end
end

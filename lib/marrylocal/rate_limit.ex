defmodule Marrylocal.RateLimit do
  use Hammer, backend: :ets
  @moduledoc """
  A module to handle rate limiting using the Hammer library.
  """

  @doc """
  Checks if a given key has exceeded the specified limit within the time window.

  ## Examples

      iex> Marrylocal.RateLimit.check_rate("login_attempts:123", 5, 60_000)
      {:ok, false} # Not rate limited

      iex> Marrylocal.RateLimit.check_rate("login_attempts:123", 5, 60_000)
      {:ok, true} # Rate limited

  """
  def check_rate(key, limit, time_window_ms) do
    case Hammer.check_rate(key, time_window_ms, limit) do
      {:ok, count} when count <= limit -> {:ok, false}
      {:ok, _count} -> {:ok, true}
      {:error, reason} -> {:error, reason}
    end
  end

end

defmodule Marrylocal.RateLimit do
  use Hammer, backend: :ets

  @moduledoc """
  Hammer-backed rate limiting helpers.
  """

  @doc """
  Increments the key and reports whether it is still inside the limit.
  """
  def check_rate(key, limit, time_window_ms) do
    case hit(key, time_window_ms, limit) do
      {:allow, _count} -> {:ok, false}
      {:deny, _retry_after} -> {:ok, true}
    end
  end

  @doc """
  Non-incrementing check used before a separate `hit/3`.
  """
  def check(key, limit, time_window_ms) do
    case get(key, time_window_ms) do
      count when count < limit -> {:allow, count}
      _count -> {:deny, 0}
    end
  end
end

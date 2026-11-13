defmodule Marrylocal.Verification.VouchCache do
  @moduledoc """
  ETS-backed single-use rotating token cache for peer verification QR codes.

  Tokens are bound to the vouchee's user id, valid for exactly 60 seconds, and
  removed atomically on first consumption. A recently expired token still
  returns `{:error, :token_expired}`; older entries are swept in the background.

  The store is node-local. The current deployment runs a single application
  node; if the app is ever scaled horizontally, token generation and
  consumption for one vouch must reach the same node (sticky routing) or the
  store must move to a shared backend.
  """

  use GenServer

  @table __MODULE__
  @ttl_ms 60_000
  @sweep_interval_ms 30_000
  @sweep_grace_ms 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Generates a URL-safe token bound to the vouchee user id."
  def generate_token(user_id) when is_integer(user_id) do
    GenServer.call(__MODULE__, {:generate, user_id})
  end

  @doc "Atomically consumes a token, returning the vouchee user id."
  def consume_token(token) when is_binary(token) do
    GenServer.call(__MODULE__, {:consume, token})
  end

  @impl GenServer
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :timer.send_interval(@sweep_interval_ms, :sweep)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:generate, user_id}, _from, state) do
    token =
      :crypto.strong_rand_bytes(32)
      |> Base.url_encode64(padding: false)

    expires_at = System.monotonic_time(:millisecond) + @ttl_ms
    :ets.insert(@table, {token, user_id, expires_at})

    {:reply, token, state}
  end

  def handle_call({:consume, token}, _from, state) do
    reply =
      case :ets.take(@table, token) do
        [{^token, user_id, expires_at}] ->
          if System.monotonic_time(:millisecond) < expires_at do
            {:ok, user_id}
          else
            {:error, :token_expired}
          end

        [] ->
          {:error, :token_invalid}
      end

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - @sweep_grace_ms

    @table
    |> :ets.tab2list()
    |> Enum.each(fn {token, _user_id, expires_at} ->
      if expires_at < cutoff, do: :ets.delete(@table, token)
    end)

    {:noreply, state}
  end
end

defmodule EventBuffer do
  @moduledoc """
  Bounded FIFO event ring buffer implemented as a GenServer.
  """

  use GenServer

  def start_link(opts \\ []) do
    max_size = Keyword.get(opts, :max_size, 100)
    GenServer.start_link(__MODULE__, max_size, Keyword.take(opts, [:name]))
  end

  def push(server, event) do
    GenServer.cast(server, {:push, event})
  end

  def list(server) do
    GenServer.call(server, :list)
  end

  @impl true
  def init(max_size) when is_integer(max_size) and max_size > 0 do
    {:ok, %{max_size: max_size, events: []}}
  end

  @impl true
  def handle_cast({:push, event}, state) do
    events = state.events ++ [event]
    {:noreply, %{state | events: events}}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, state.events, state}
  end

  @impl true
  def handle_info(:clear, state) do
    {:noreply, %{state | events: []}}
  end
end

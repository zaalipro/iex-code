defmodule IexCode.Engine.ExecutionStream do
  @moduledoc """
  Invocation-local, ephemeral PubSub snapshots. Never writes conversation storage.

  `:complete` means the role/model invocation returned, NOT durable success.
  Only persisted final messages and execution terminal state establish success.
  See docs/execution-stream.md for the consumer ordering/reconciliation contract.
  """
  use GenServer, restart: :temporary

  alias IexCode.LLM.ThinkTagParser

  @chunk_bytes 4096
  @preview_bytes 16_384

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def scope(session_id, role, opts \\ []) do
    owner = Process.get(:iex_code_fleet_owner) || %{}
    execution_id = opts[:execution_id] || opts[:run_id] || Ecto.UUID.generate()
    attempt = opts[:run_attempt] || 1

    %{
      session_id: session_id,
      execution_id: execution_id,
      attempt: attempt,
      attempt_id: "#{execution_id}:#{attempt}",
      generation: opts[:run_lease_generation] || 1,
      agent_id: owner[:agent_id],
      agent_generation: owner[:generation],
      role: to_string(role),
      invocation_id: Ecto.UUID.generate(),
      turn: 1
    }
  end

  def with_stream(identity, fun) do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        IexCode.Engine.ExecutionStreamSupervisor,
        {__MODULE__, identity: identity, owner: self()}
      )

    try do
      result = fun.(pid)
      finish(pid, result_status(result))
      result
    after
      finish(pid, :failed)
    end
  end

  def identity(pid), do: GenServer.call(pid, :identity)

  def metadata_identity(pid),
    do: identity(pid) |> Map.new(fn {key, value} -> {to_string(key), value} end)

  def callback(pid) do
    invocation_id = identity(pid).invocation_id
    fn chunk -> push_callback(pid, invocation_id, chunk) end
  end

  defp push_callback(pid, invocation, chunk)
       when is_binary(chunk) and byte_size(chunk) > @chunk_bytes do
    <<part::binary-size(@chunk_bytes), rest::binary>> = chunk
    push_callback(pid, invocation, part)
    push_callback(pid, invocation, rest)
  end

  defp push_callback(pid, invocation, chunk), do: safe_call(pid, {:callback, invocation, chunk})
  def turn(pid, turn), do: GenServer.call(pid, {:turn, turn})

  # Synchronous, fixed-sized calls bound mailbox pressure and parser allocation.
  # A helper that has already terminalized cannot be resurrected by a callback.
  def push(pid, chunk) when is_binary(chunk) and byte_size(chunk) > @chunk_bytes do
    <<part::binary-size(@chunk_bytes), rest::binary>> = chunk
    push(pid, part)
    push(pid, rest)
  end

  def push(pid, chunk), do: safe_call(pid, {:chunk, chunk})
  def finish(pid, status), do: safe_call(pid, {:finish, status})

  defp safe_call(pid, message) do
    GenServer.call(pid, message)
  catch
    :exit, _ -> :ok
  end

  defp result_status({:ok, %{message_id: _}}), do: :settled
  defp result_status({:ok, _}), do: :complete
  defp result_status({:error, :cancelled}), do: :cancelled
  defp result_status({:pause, _}), do: :paused
  defp result_status(_), do: :failed

  @impl true
  def init(opts) do
    state = %{
      identity: Map.put(Keyword.fetch!(opts, :identity), :retry_epoch, 0),
      owner_ref: Process.monitor(Keyword.fetch!(opts, :owner)),
      sequence: 0,
      text: "",
      reasoning: "",
      truncated?: false,
      parser: ThinkTagParser.new(),
      utf8: "",
      dirty?: false,
      timer: nil,
      batch_ms: min(max(Keyword.get(opts, :batch_ms, 75), 1), 1000),
      cap: min(max(Keyword.get(opts, :preview_bytes, @preview_bytes), 1), @preview_bytes)
    }

    {:ok, emit(state, :started)}
  end

  @impl true
  def handle_call(:identity, _from, state), do: {:reply, state.identity, state}

  def handle_call({:turn, turn}, _from, state) when turn == state.identity.turn,
    do: {:reply, :ok, state}

  def handle_call({:turn, turn}, _from, state) do
    state = state |> flush() |> emit(:complete) |> reset()

    state = %{
      state
      | identity: %{
          state.identity
          | turn: turn,
            retry_epoch: 0,
            invocation_id: Ecto.UUID.generate()
        }
    }

    {:reply, :ok, emit(state, :started)}
  end

  def handle_call({:chunk, {:stream_reset, _attempt}}, _from, state) do
    epoch = state.identity.retry_epoch + 1
    state = reset(state)
    {:reply, :ok, emit(%{state | identity: %{state.identity | retry_epoch: epoch}}, :reset)}
  end

  def handle_call({:chunk, chunk}, _from, state) when is_binary(chunk) do
    {valid, carry} = decode(state.utf8 <> chunk)
    {text, reasoning, parser} = ThinkTagParser.process_chunk(state.parser, valid)
    parser = %{parser | buffer: :binary.copy(parser.buffer)}
    state = append(%{state | parser: parser, utf8: :binary.copy(carry)}, text, reasoning)
    state = schedule(state)
    {:reply, :ok, state}
  end

  def handle_call({:callback, invocation_id, {:stream_reset, attempt}}, _from, state)
      when invocation_id == state.identity.invocation_id do
    handle_call({:chunk, {:stream_reset, attempt}}, self(), state)
  end

  def handle_call({:callback, invocation_id, chunk}, _from, state)
      when invocation_id == state.identity.invocation_id and is_binary(chunk) do
    handle_call({:chunk, chunk}, self(), state)
  end

  def handle_call({:callback, _stale_invocation, _chunk}, _from, state),
    do: {:reply, :ignored, state}

  def handle_call({:chunk, _}, _from, state), do: {:reply, :ok, state}

  def handle_call({:finish, status}, _from, state) do
    {:stop, :normal, :ok, state |> flush() |> emit(status)}
  end

  @impl true
  def handle_info({:flush, token}, %{timer: {_timer, token}} = state) do
    {:noreply, emit(%{state | timer: nil}, :streaming)}
  end

  def handle_info({:flush, _old_token}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state) do
    {:stop, :normal, state |> flush() |> emit(:owner_down)}
  end

  @impl true
  def terminate(_reason, state), do: cancel_timer(state.timer)

  defp reset(state) do
    cancel_timer(state.timer)

    %{
      state
      | text: "",
        reasoning: "",
        truncated?: false,
        parser: ThinkTagParser.new(),
        utf8: "",
        dirty?: false,
        timer: nil
    }
  end

  defp flush(state) do
    cancel_timer(state.timer)
    {text, reasoning, parser} = ThinkTagParser.flush(state.parser)
    append(%{state | timer: nil, parser: parser, utf8: ""}, text, reasoning)
  end

  defp append(state, text, reasoning) do
    {answer, answer_cut?} = capped(state.text, text, state.cap)
    {thought, thought_cut?} = capped(state.reasoning, reasoning, state.cap)
    cut? = state.truncated? or answer_cut? or thought_cut?

    %{
      state
      | text: answer,
        reasoning: thought,
        truncated?: cut?,
        dirty?:
          state.dirty? or answer != state.text or thought != state.reasoning or
            cut? != state.truncated?
    }
  end

  defp capped(current, delta, cap) do
    remaining = cap - byte_size(current)

    if byte_size(delta) <= remaining do
      {:binary.copy(current <> delta), false}
    else
      {valid, _carry} = decode(binary_part(delta, 0, remaining))
      {:binary.copy(current <> valid), true}
    end
  end

  defp decode(data) do
    case :unicode.characters_to_binary(data, :utf8, :utf8) do
      valid when is_binary(valid) -> {valid, ""}
      {:incomplete, valid, rest} -> {valid, rest}
      {:error, valid, _rest} -> {valid, ""}
    end
  end

  defp schedule(%{timer: nil, dirty?: true} = state) do
    token = make_ref()
    %{state | timer: {Process.send_after(self(), {:flush, token}, state.batch_ms), token}}
  end

  defp schedule(state), do: state

  defp emit(state, status) do
    sequence = state.sequence + 1

    event = %{
      identity: state.identity,
      sequence: sequence,
      status: status,
      text: state.text,
      reasoning: state.reasoning,
      truncated?: state.truncated?
    }

    Phoenix.PubSub.broadcast(
      IexCode.PubSub,
      "session:#{state.identity.session_id}",
      {:execution_stream, event}
    )

    %{state | sequence: sequence, dirty?: false}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer({timer, _token}), do: Process.cancel_timer(timer)
end

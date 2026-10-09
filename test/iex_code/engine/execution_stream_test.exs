defmodule IexCode.Engine.ExecutionStreamTest do
  use ExUnit.Case, async: false

  alias IexCode.Engine.ExecutionStream

  setup do
    session_id = Ecto.UUID.generate()
    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session_id}")

    identity = %{
      session_id: session_id,
      execution_id: "execution",
      attempt: 2,
      generation: 3,
      role: "coder",
      invocation_id: Ecto.UUID.generate(),
      turn: 1
    }

    %{identity: identity}
  end

  test "coalesces bounded snapshots and flushes the unbatched tail on settlement", ctx do
    pid =
      start_supervised!({ExecutionStream, identity: ctx.identity, owner: self(), batch_ms: 1000})

    assert_receive {:execution_stream, %{status: :started, sequence: 1}}

    for _ <- 1..400, do: ExecutionStream.push(pid, "a")
    refute_receive {:execution_stream, %{status: :streaming}}, 0
    ExecutionStream.finish(pid, :settled)
    assert_receive {:execution_stream, event}
    assert event.status == :settled
    assert event.text == String.duplicate("a", 400)
    assert event.identity == Map.put(ctx.identity, :retry_epoch, 0)
    assert event.sequence == 2
    assert ExecutionStream.push(pid, "late") == :ok
    refute_receive {:execution_stream, _}, 0
  end

  test "timer sends text before completion without one broadcast per chunk", ctx do
    pid = start_supervised!({ExecutionStream, identity: ctx.identity, owner: self()})
    assert_receive {:execution_stream, %{status: :started}}
    for _ <- 1..100, do: ExecutionStream.push(pid, "x")
    assert_receive {:execution_stream, %{status: :streaming, text: text}}, 1000
    assert text == String.duplicate("x", 100)
    refute_receive {:execution_stream, _}, 0
    ExecutionStream.finish(pid, :cancelled)
    assert_receive {:execution_stream, %{status: :cancelled}}
  end

  test "retry clears only this invocation including parser carry and increments its epoch", ctx do
    first =
      start_supervised!({ExecutionStream, identity: ctx.identity, owner: self()}, id: :first)

    second_identity = %{ctx.identity | invocation_id: "other", turn: 2}

    second =
      start_supervised!({ExecutionStream, identity: second_identity, owner: self()}, id: :second)

    ExecutionStream.push(first, "abandoned<th")
    ExecutionStream.push(second, "retained")
    ExecutionStream.push(first, {:stream_reset, 1})
    ExecutionStream.push(first, {:stream_reset, 1})
    ExecutionStream.push(first, "replacement")
    ExecutionStream.finish(first, :settled)
    ExecutionStream.finish(second, :settled)
    assert_receive {:execution_stream, %{status: :reset, text: "", identity: %{retry_epoch: 1}}}
    assert_receive {:execution_stream, %{status: :reset, text: "", identity: %{retry_epoch: 2}}}

    assert_receive {:execution_stream,
                    %{status: :settled, text: "replacement", identity: %{retry_epoch: 2}}}

    assert_receive {:execution_stream,
                    %{status: :settled, text: "retained", identity: %{retry_epoch: 0}}}
  end

  test "caps retained bytes and separates split think tags and UTF8", ctx do
    pid =
      start_supervised!(
        {ExecutionStream, identity: ctx.identity, owner: self(), preview_bytes: 16}
      )

    ExecutionStream.push(pid, "<thi")
    ExecutionStream.push(pid, "nk>secret</th")
    ExecutionStream.push(pid, "ink>" <> <<0xF0, 0x9F>>)
    ExecutionStream.push(pid, <<0x98, 0x80>> <> String.duplicate("é", 100_000))
    ExecutionStream.finish(pid, :settled)
    assert_receive {:execution_stream, %{status: :settled} = event}
    assert event.text == "😀" <> String.duplicate("é", 6)
    assert event.reasoning == "secret"
    assert event.truncated?
    assert String.valid?(event.text)
    assert byte_size(event.text) <= 16
    assert byte_size(event.reasoning) <= 16
  end

  test "owner death marks partial output and stops helper normally", ctx do
    owner =
      start_supervised!(
        {Task,
         fn ->
           receive do
             :finish -> :ok
           end
         end}
      )

    pid = start_supervised!({ExecutionStream, identity: ctx.identity, owner: owner})
    monitor = Process.monitor(pid)
    ExecutionStream.push(pid, "partial")
    send(owner, :finish)
    assert_receive {:execution_stream, %{status: :owner_down, text: "partial"}}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end

  test "a previous turn callback cannot contaminate a later invocation", ctx do
    pid = start_supervised!({ExecutionStream, identity: ctx.identity, owner: self()})
    old = ExecutionStream.callback(pid)
    old.("first")
    ExecutionStream.turn(pid, 2)
    current = ExecutionStream.callback(pid)
    old.("stale")
    old.({:stream_reset, 1})
    current.("second")
    ExecutionStream.finish(pid, :settled)
    assert_receive {:execution_stream, %{status: :settled, text: "second", identity: identity}}
    assert identity.turn == 2
    assert identity.retry_epoch == 0
    refute identity.invocation_id == ctx.identity.invocation_id
  end

  test "exception and cancellation terminalize supervised helpers without late output", ctx do
    receiver = self()

    assert_raise RuntimeError, "provider failed", fn ->
      ExecutionStream.with_stream(ctx.identity, fn pid ->
        send(receiver, {:helper, pid})
        ExecutionStream.push(pid, "partial")
        raise "provider failed"
      end)
    end

    assert_receive {:helper, pid}
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :noproc}
    assert_receive {:execution_stream, %{status: :failed, text: "partial"}}

    assert {:error, :cancelled} =
             ExecutionStream.with_stream(ctx.identity, fn pid ->
               ExecutionStream.push(pid, "partial")
               {:error, :cancelled}
             end)

    assert_receive {:execution_stream, %{status: :cancelled}}
  end

  test "actual resilience resets abandon partial response without mixing prefixes", ctx do
    counter = start_supervised!({Agent, fn -> 0 end})

    ExecutionStream.with_stream(ctx.identity, fn pid ->
      callback = ExecutionStream.callback(pid)

      IexCode.LLM.Resilience.with_retry(
        fn ->
          attempt = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

          if attempt == 1 do
            callback.("abandoned<th")
            {:error, %{status: 500}}
          else
            callback.("replacement")
            {:ok, "replacement"}
          end
        end,
        max_retries: 1,
        base_backoff_ms: 0,
        jitter: :none,
        on_chunk: callback
      )
    end)

    assert_receive {:execution_stream, %{status: :reset, text: ""}}

    assert_receive {:execution_stream,
                    %{status: :complete, text: "replacement", identity: %{retry_epoch: 1}}}
  end

  test "chunk growth adds no SQLite queries and preview bytes stay fixed", ctx do
    for count <- [4, 4000] do
      identity = %{ctx.identity | invocation_id: Ecto.UUID.generate()}

      pid =
        start_supervised!({ExecutionStream, identity: identity, owner: self(), batch_ms: 1000},
          id: make_ref()
        )

      {_result, metrics} =
        IexCode.Test.LeanHarnessCollector.measure(fn ->
          for _ <- 1..count, do: ExecutionStream.push(pid, String.duplicate("a", 4096))
          ExecutionStream.finish(pid, :settled)
        end)

      assert metrics.query_count == 0
      assert_receive {:execution_stream, %{status: :settled, identity: event_identity} = event}
      assert event_identity == Map.put(identity, :retry_epoch, 0)
      assert byte_size(event.text) == 16_384

      IexCode.Test.LeanHarnessCollector.emit(
        "stream_preview",
        %{chunks: count, chunk_bytes: 4096},
        Map.merge(metrics, %{
          preview_bytes: byte_size(event.text),
          updates: event.sequence,
          provider_usage: nil
        })
      )
    end
  end
end

Code.require_file("lib/event_buffer.ex", __DIR__)

ExUnit.start(autorun: false)

defmodule EventBufferGradeTest do
  use ExUnit.Case

  test "bounds retained events to max_size keeping newest in order" do
    {:ok, pid} = EventBuffer.start_link(max_size: 3)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    for i <- 1..5 do
      EventBuffer.push(pid, i)
    end

    assert EventBuffer.list(pid) == [3, 4, 5]
  end

  test "ignores unexpected info messages without crashing" do
    Process.flag(:trap_exit, true)
    {:ok, pid} = EventBuffer.start_link(max_size: 2)
    ref = Process.monitor(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    EventBuffer.push(pid, :keep)
    send(pid, {:unexpected_message, :noise})

    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 50
    _ = :sys.get_state(pid)
    assert Process.alive?(pid)
    assert EventBuffer.list(pid) == [:keep]

    send(pid, :clear)
    _ = :sys.get_state(pid)
    assert EventBuffer.list(pid) == []
  end
end

case ExUnit.run() do
  %{failures: 0} -> System.halt(0)
  _ -> System.halt(1)
end

defmodule IexCode.Tools.BoundedDirectoryTest do
  use ExUnit.Case, async: false
  alias IexCode.Tools.BoundedDirectory

  setup do
    root =
      Path.join(
        "/tmp/iex-code-readiness-_5wuredz/tmp",
        "bounded-directory-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{supervisor: start_supervised!({Task.Supervisor, []}), tmp_dir: root}
  end

  test "real helper bounds yielded names and discards unfinished listings", context do
    %{tmp_dir: root, supervisor: supervisor} = context

    for name <- ["z", "a\nb", "-'$(touch nope)'", "normal"],
        do: File.write!(Path.join(root, name), "")

    assert {:ok, worker} = BoundedDirectory.open(supervisor: supervisor)
    port = owned_port(worker)
    os_pid = Port.info(port, :os_pid) |> elem(1)

    assert {:ok, names, %{entries: 4, wire_bytes: bytes}} =
             BoundedDirectory.list(worker, root, 10, 100_000)

    assert Enum.sort(names) == ["-'$(touch nope)'", "a\nb", "normal", "z"]
    assert bytes < 100_000
    refute File.exists?(Path.join(root, "nope"))

    assert {:incomplete, :entries, %{entries: 2}} =
             BoundedDirectory.list(worker, root, 2, 100_000)

    assert {:incomplete, :entries, %{entries: 4}} =
             BoundedDirectory.list(worker, root, 4, 100_000)

    assert {:incomplete, :wire, %{wire_bytes: used}} = BoundedDirectory.list(worker, root, 10, 32)
    assert used <= 32

    assert :ok = BoundedDirectory.close(worker)
    assert_os_exit(os_pid)
    refute port in Port.list()
  end

  test "caller death closes actual helper and supervised worker", context do
    receiver = self()
    %{supervisor: supervisor} = context

    {:ok, owner} =
      Task.Supervisor.start_child(supervisor, fn ->
        {:ok, worker} = BoundedDirectory.open(supervisor: supervisor)
        send(receiver, {:ready, worker})
        receive do: (:release -> :ok)
      end)

    assert_receive {:ready, worker}
    port = owned_port(worker)
    os_pid = Port.info(port, :os_pid) |> elem(1)
    monitor = Process.monitor(worker)
    owner_monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    assert_os_exit(os_pid)
    refute port in Port.list()
  end

  test "pending helper request times out and cleans up instead of falling back", context do
    %{tmp_dir: root, supervisor: supervisor} = context
    helper = Path.join(root, "blocked.py")
    File.write!(helper, "import time\nwhile True: time.sleep(60)\n")

    assert {:ok, worker} =
             BoundedDirectory.open(supervisor: supervisor, helper: helper, timeout_ms: 50)

    port = owned_port(worker)
    os_pid = Port.info(port, :os_pid) |> elem(1)
    monitor = Process.monitor(worker)
    assert {:error, :timeout} = BoundedDirectory.list(worker, root, 10, 100_000)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    assert_os_exit(os_pid)
    refute port in Port.list()
  end

  test "helper failures and outward directory links cannot yield outside names", context do
    %{tmp_dir: root, supervisor: supervisor} = context
    outside = Path.join(root, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "OUTSIDE_SENTINEL"), "")
    link = Path.join(root, "link")
    File.ln_s!(outside, link)
    assert {:ok, worker} = BoundedDirectory.open(supervisor: supervisor)
    assert {:skip, %{entries: 0}} = BoundedDirectory.list(worker, link, 10, 100_000)
    assert :ok = BoundedDirectory.close(worker)

    assert {:error, :helper_unavailable} =
             BoundedDirectory.open(supervisor: supervisor, python: Path.join(root, "missing"))

    assert {:error, :helper_unavailable} =
             BoundedDirectory.open(supervisor: supervisor, helper: Path.join(root, "missing"))

    helper = Path.join(root, "malformed.py")

    File.write!(
      helper,
      "import sys\nheader = sys.stdin.buffer.read(2)\nsys.stdin.buffer.read(int.from_bytes(header, 'big'))\nsys.stdout.buffer.write(b'\\x00\\x03bad')\nsys.stdout.buffer.flush()\nsys.stdin.buffer.read(1)\n"
    )

    assert {:ok, worker} = BoundedDirectory.open(supervisor: supervisor, helper: helper)
    port = owned_port(worker)
    os_pid = Port.info(port, :os_pid) |> elem(1)
    monitor = Process.monitor(worker)
    assert {:error, _} = BoundedDirectory.list(worker, root, 10, 100_000)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    assert_os_exit(os_pid)
  end

  defp owned_port(worker) do
    Enum.find(Port.list(), &(Port.info(&1, :connected) == {:connected, worker}))
  end

  defp assert_os_exit(pid) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    await_os_exit(pid, deadline)
  end

  defp await_os_exit(pid, deadline) do
    case System.cmd("/bin/ps", ["-p", Integer.to_string(pid), "-o", "pid="]) do
      {_, 1} ->
        :ok

      {output, 0} ->
        assert System.monotonic_time(:millisecond) < deadline,
               "Directory helper still running: #{output}"

        receive after: (10 -> await_os_exit(pid, deadline))
    end
  end
end

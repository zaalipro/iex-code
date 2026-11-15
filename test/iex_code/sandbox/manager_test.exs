defmodule IexCode.Sandbox.ManagerTest do
  use ExUnit.Case, async: false

  alias IexCode.Sandbox.{Backend, Manager, Policy}

  setup do
    server =
      start_supervised!({Manager, name: :"sandbox_#{System.unique_integer([:positive])}"})

    %{server: server}
  end

  test "approvals grant and expire", %{server: server} do
    refute Manager.approved?(server, "rm -rf /")

    assert {:ok, %{fingerprint: fp}} = Manager.approve(server, "rm -rf /")
    assert is_binary(fp)
    assert Manager.approved?(server, "rm -rf /")
    refute Manager.approved?(server, "rm -rf / ")
  end

  test "zero ttl approvals are immediately dead", %{server: server} do
    {:ok, _} = Manager.approve(server, "echo hi", ttl_ms: 0)
    refute Manager.approved?(server, "echo hi")
  end

  test "fingerprints are stable and argv-aware" do
    assert Manager.fingerprint(["a", "b"]) == Manager.fingerprint("a\0b")
    refute Manager.fingerprint(["a", "b"]) == Manager.fingerprint(["ab"])
  end

  test "strict policy fails closed without a backend", %{server: server} do
    assert {:error, :no_sandbox_backend} =
             Manager.run(["echo", "hi"], %Policy{strict: true}, backend: :none, server: server)
  end

  test "non-strict without a backend runs flagged unconfined", %{server: server} do
    assert {:ok, result} =
             Manager.run(["echo", "hi"], %Policy{strict: false},
               backend: :none,
               server: server
             )

    assert result.exit_code == 0
    assert result.output =~ "hi"
    assert result.confined == false
    assert result.backend == :unconfined
  end

  test "required approvals gate execution", %{server: server} do
    argv = ["echo", "gated"]

    assert {:error, :sandbox_approval_required} =
             Manager.run(argv, %Policy{strict: false},
               backend: :none,
               server: server,
               require_approval: true
             )

    {:ok, _} = Manager.approve(server, Enum.join(argv, "\0"))

    assert {:ok, %{exit_code: 0}} =
             Manager.run(argv, %Policy{strict: false},
               backend: :none,
               server: server,
               require_approval: true
             )
  end

  test "real backend executes confined commands", %{server: server} do
    case Backend.detect() do
      :none ->
        assert {:error, :no_sandbox_backend} =
                 Manager.run(["echo", "hi"], %Policy{}, server: server)

      backend ->
        policy = Policy.for_workdir(System.tmp_dir!())

        assert {:ok, result} =
                 Manager.run(["echo", "confined-hi"], policy,
                   server: server,
                   backend: backend,
                   timeout_ms: 15_000
                 )

        assert result.exit_code == 0
        assert result.output =~ "confined-hi"
        assert result.confined == true
        assert result.backend == backend
    end
  end

  test "missing commands and empty argv error", %{server: server} do
    assert {:error, {:sandbox_no_command, _}} =
             Manager.run(["definitely-not-a-real-binary-xyz"], %Policy{strict: false},
               backend: :none,
               server: server
             )

    assert {:error, :sandbox_empty_command} = Manager.run([], %Policy{}, server: server)
  end

  test "prunes expired approvals on lookup/write and caps approvals at 1024 entries", %{
    server: server
  } do
    assert {:ok, _} = Manager.approve(server, "short-cmd", ttl_ms: 1)
    assert :ok = wait_until_unapproved(server, "short-cmd", 1_000)

    # Expired entry was pruned from state on lookup
    assert :sys.get_state(server).approvals == %{}

    # Default cap is 1,024 entries: adding 1,025 evicts oldest entry
    Enum.each(1..1_025, fn idx ->
      assert {:ok, _} = Manager.approve(server, "cmd-#{idx}", ttl_ms: 60_000)
    end)

    state = :sys.get_state(server)
    assert map_size(state.approvals) == 1_024
    refute Manager.approved?(server, "cmd-1")
    assert Manager.approved?(server, "cmd-2")
    assert Manager.approved?(server, "cmd-1025")

    # Custom bounded server capacity also works cleanly
    bounded = :"bounded_mgr_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec({Manager, name: bounded, max_approvals: 2}, id: bounded)
    )

    assert {:ok, _} = Manager.approve(bounded, "first", ttl_ms: 60_000)
    assert {:ok, _} = Manager.approve(bounded, "second", ttl_ms: 60_000)
    assert {:ok, _} = Manager.approve(bounded, "third", ttl_ms: 60_000)

    assert map_size(:sys.get_state(bounded).approvals) == 2
    refute Manager.approved?(bounded, "first")
    assert Manager.approved?(bounded, "second")
    assert Manager.approved?(bounded, "third")
  end

  test "rejects policy injection payloads before execution", %{server: server} do
    bad_policy = %Policy{reads: ["/"], writes: ["/tmp/evil\n(allow default)"], strict: true}

    assert {:error, {:sandbox_policy_field, "writes"}} =
             Manager.run(["echo", "hi"], bad_policy, server: server)
  end

  defp wait_until_unapproved(server, command, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_unapproved(server, command, deadline)
  end

  defp do_wait_until_unapproved(server, command, deadline) do
    if not Manager.approved?(server, command) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("approval for #{command} did not expire in time")
      else
        _ref = Process.send_after(self(), :poll_expiry, 5)

        receive do
          :poll_expiry -> do_wait_until_unapproved(server, command, deadline)
        end
      end
    end
  end
end

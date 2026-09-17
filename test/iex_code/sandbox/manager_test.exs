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
end

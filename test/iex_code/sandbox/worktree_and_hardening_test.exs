defmodule IexCode.Sandbox.WorktreeAndHardeningTest do
  use IexCode.DataCase, async: false

  alias IexCode.Projects.Project
  alias IexCode.Repo
  alias IexCode.Sandbox.{Backend, Manager, Policy, Worktree}
  alias IexCode.WorkspaceLocks

  defp make_temp_dir(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "iex_code_#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp init_git_repo(prefix) do
    repo = make_temp_dir(prefix)
    git!(repo, ["init", "-q"])
    git!(repo, ["config", "user.email", "test@example.com"])
    git!(repo, ["config", "user.name", "Test User"])

    File.mkdir_p!(Path.join(repo, "lib"))
    File.write!(Path.join(repo, "README.md"), "# Demo\n")
    File.write!(Path.join(repo, "lib/app.ex"), "defmodule App, do: def v, do: 1\n")

    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "initial commit"])
    repo
  end

  defp git!(dir, args) do
    {out, 0} =
      System.cmd("git", args,
        cd: dir,
        stderr_to_stdout: true,
        env: [{"GIT_TERMINAL_PROMPT", "0"}]
      )

    out
  end

  defp wait_until_pids(path, expected_count, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_pids(path, expected_count, deadline)
  end

  defp do_wait_until_pids(path, expected_count, deadline) do
    pids =
      case File.read(path) do
        {:ok, raw} ->
          raw
          |> String.split(~r/\s+/, trim: true)
          |> Enum.filter(&Regex.match?(~r/^\d+$/, &1))
          |> Enum.map(&String.to_integer/1)

        _ ->
          []
      end

    if length(pids) >= expected_count do
      pids
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("timed out waiting for #{expected_count} PIDs in #{path}, got #{inspect(pids)}")
      else
        _ref = Process.send_after(self(), :poll_pids, 20)

        receive do
          :poll_pids -> do_wait_until_pids(path, expected_count, deadline)
        end
      end
    end
  end

  defp wait_until_pid_dead(pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_pid_dead(pid, deadline)
  end

  defp do_wait_until_pid_dead(pid, deadline) do
    {_, code} = System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

    if code != 0 do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("OS process #{pid} remained alive past deadline")
      else
        _ref = Process.send_after(self(), :poll_dead, 20)

        receive do
          :poll_dead -> do_wait_until_pid_dead(pid, deadline)
        end
      end
    end
  end

  describe "macOS Seatbelt profile hardening and child-process confinement" do
    test "seatbelt profile removes (with no-sandbox), enables confined fork/exec, and escapes backslashes before quotes" do
      policy = %Policy{
        reads: ["/tmp/alpha", "/var/beta"],
        writes: [~S(/tmp/with\slash"quote)],
        network: :deny
      }

      profile = Backend.seatbelt_profile(policy)

      assert profile =~ "(allow process-exec)"
      assert profile =~ "(allow process-fork)"
      refute profile =~ "no-sandbox"
      assert profile =~ ~S|(subpath "/tmp/with\\slash\"quote")|

      if match?({:unix, :darwin}, :os.type()) do
        assert profile =~ ~s|(subpath "/private/tmp/alpha")|
        assert profile =~ ~s|(subpath "/private/var/beta")|
      end
    end

    test "nested spawned subshells remain confined inside Seatbelt sandbox" do
      if Backend.detect() == :sandbox_exec do
        server = :"mgr_seatbelt_#{System.unique_integer([:positive])}"
        start_supervised!({Manager, name: server})

        workdir = make_temp_dir("sbx_inside")
        outside_dir = make_temp_dir("sbx_outside")

        inside_file = Path.join(workdir, "allowed.txt")
        secret_file = Path.join(outside_dir, "secret.txt")
        outside_target = Path.join(outside_dir, "escape_write.txt")
        File.write!(secret_file, "TOP_SECRET_OUTSIDE_TOKEN\n")

        policy = %Policy{
          reads: [workdir],
          writes: [workdir],
          network: :deny,
          strict: true
        }

        # Nested /bin/sh child works inside workdir
        ok_cmd = "/bin/sh -c \"echo nested_ok > '#{inside_file}' && /bin/cat '#{inside_file}'\""

        assert {:ok, %{exit_code: 0, output: out, confined: true, backend: :sandbox_exec}} =
                 Manager.run(["/bin/sh", "-c", ok_cmd], policy,
                   server: server,
                   workdir: workdir,
                   timeout_ms: 5_000
                 )

        assert String.trim(out) == "nested_ok"

        # Grandchild subshell CANNOT read secret outside configured read prefixes
        read_escape_cmd = "/bin/sh -c \"/bin/cat '#{secret_file}'\""

        assert {:ok, %{exit_code: code, output: escape_out, confined: true}} =
                 Manager.run(["/bin/sh", "-c", read_escape_cmd], policy,
                   server: server,
                   workdir: workdir,
                   timeout_ms: 5_000
                 )

        assert code != 0
        refute escape_out =~ "TOP_SECRET_OUTSIDE_TOKEN"

        # Grandchild subshell CANNOT write outside configured write prefixes
        write_escape_cmd = "/bin/sh -c \"echo pwned > '#{outside_target}'\""

        assert {:ok, %{exit_code: write_code, confined: true}} =
                 Manager.run(["/bin/sh", "-c", write_escape_cmd], policy,
                   server: server,
                   workdir: workdir,
                   timeout_ms: 5_000
                 )

        assert write_code != 0
        refute File.exists?(outside_target)
      end
    end

    test "Manager.run reaps entire OS process group on timeout without leaking grandchild processes" do
      server = :"mgr_pgroup_#{System.unique_integer([:positive])}"
      start_supervised!({Manager, name: server})

      workdir = make_temp_dir("pgroup_wd")
      pids_file = Path.join(workdir, "pids.txt")
      policy = %Policy{reads: ["/"], writes: [workdir], network: :allow, strict: false}

      script = """
      sleep 30 &
      child=$!
      printf '%s\n%s\n' "$$" "$child" > '#{pids_file}'
      wait
      """

      task =
        Task.async(fn ->
          Manager.run(["/bin/sh", "-c", script], policy,
            server: server,
            workdir: workdir,
            timeout_ms: 250
          )
        end)

      [parent_pid, child_pid] = wait_until_pids(pids_file, 2, 4_000)

      assert {:error, :sandbox_timeout} = Task.await(task, 6_000)

      assert :ok = wait_until_pid_dead(parent_pid, 4_000)
      assert :ok = wait_until_pid_dead(child_pid, 4_000)
    end
  end

  describe "Sandbox.Worktree isolated worktree lifecycle" do
    test "create/2 initializes detached and branched worktrees and rejects invalid repos or refs" do
      repo = init_git_repo("wt_create")
      base_dir = make_temp_dir("wt_base")

      assert {:ok, wt} = Worktree.create(repo, base_dir: base_dir, id: "agent_run_1")
      assert wt.detached? == true
      assert File.dir?(wt.path)

      assert String.starts_with?(wt.path, Path.expand(base_dir)) or
               String.contains?(wt.path, "agent_run_1")

      assert File.read!(Path.join(wt.path, "README.md")) == "# Demo\n"

      # Dirty file in main repo does NOT affect isolated worktree
      File.write!(Path.join(repo, "README.md"), "# Modified in main\n")
      assert File.read!(Path.join(wt.path, "README.md")) == "# Demo\n"

      # Branch creation mode
      assert {:ok, branch_wt} =
               Worktree.create(repo, base_dir: base_dir, id: "branch_run", branch: "wt/feature-1")

      assert branch_wt.detached? == false
      assert branch_wt.branch == "wt/feature-1"

      # Error cases
      non_git = make_temp_dir("not_git")
      assert {:error, :not_a_git_repo} = Worktree.create(non_git)

      assert {:error, {:invalid_base_ref, "nonexistent_ref_xyz"}} =
               Worktree.create(repo, base_ref: "nonexistent_ref_xyz")

      existing_path = make_temp_dir("already_exists")
      assert {:error, {:worktree_path_exists, _}} = Worktree.create(repo, path: existing_path)

      assert :ok = Worktree.cleanup(wt)
      assert :ok = Worktree.cleanup(branch_wt, delete_branch: true)
    end

    test "status/1, changed_files/1, and diff/2 capture modified, deleted, committed, and untracked files" do
      repo = init_git_repo("wt_diff")
      base_dir = make_temp_dir("wt_diff_base")

      assert {:ok, wt} = Worktree.create(repo, base_dir: base_dir)

      # Commit one change inside the worktree
      File.write!(Path.join(wt.path, "lib/app.ex"), "defmodule App, do: def v, do: 2\n")
      git!(wt.path, ["add", "lib/app.ex"])
      git!(wt.path, ["commit", "-q", "-m", "bump version"])

      # Unstaged deletion + nested untracked file
      File.rm!(Path.join(wt.path, "README.md"))
      File.mkdir_p!(Path.join(wt.path, "lib/sub"))
      File.write!(Path.join(wt.path, "lib/sub/new.ex"), "defmodule App.New, do: nil\n")

      assert {:ok, status_res} = Worktree.status(wt)
      assert %{status: :deleted, path: "README.md"} in status_res.unstaged
      assert "lib/sub/new.ex" in status_res.untracked

      assert {:ok, changed} = Worktree.changed_files(wt)
      assert Enum.sort(changed) == ["README.md", "lib/app.ex", "lib/sub/new.ex"]

      assert {:ok, full_diff} = Worktree.diff(wt)
      assert full_diff =~ "defmodule App, do: def v, do: 2"
      assert full_diff =~ "-# Demo"
      assert full_diff =~ "+defmodule App.New, do: nil"

      assert {:ok, stat_diff} = Worktree.diff(wt, stat: true)
      assert stat_diff =~ "lib/app.ex"
      assert stat_diff =~ "README.md"

      assert {:ok, filtered_diff} =
               Worktree.diff(wt, paths: ["lib/app.ex"], include_untracked: false)

      assert filtered_diff =~ "def v, do: 2"
      refute filtered_diff =~ "App.New"

      assert :ok = Worktree.cleanup(wt)
    end

    test "apply_back/3 atomically applies changes, preserves permissions, supports subsets, and cleans up cleanly" do
      repo = init_git_repo("wt_apply")
      base_dir = make_temp_dir("wt_apply_base")
      assert {:ok, wt} = Worktree.create(repo, base_dir: base_dir)

      script_path = Path.join(wt.path, "bin/run.sh")
      File.mkdir_p!(Path.dirname(script_path))
      File.write!(script_path, "#!/bin/sh\necho ok\n")
      File.chmod!(script_path, 0o755)

      File.write!(Path.join(wt.path, "lib/app.ex"), "defmodule App, do: def v, do: :updated\n")
      File.rm!(Path.join(wt.path, "README.md"))

      # Subset apply first: only README.md deletion
      assert {:ok, subset_summary} = Worktree.apply_back(wt, repo, paths: ["README.md"])
      assert subset_summary.deleted_files == ["README.md"]
      refute File.exists?(Path.join(repo, "README.md"))
      # Untouched yet
      assert File.read!(Path.join(repo, "lib/app.ex")) == "defmodule App, do: def v, do: 1\n"

      # Full apply remaining changes with cleanup: true
      assert {:ok, summary} = Worktree.apply_back(wt, repo, cleanup: true)
      assert Enum.sort(summary.applied_files) == ["bin/run.sh", "lib/app.ex"]

      assert File.read!(Path.join(repo, "lib/app.ex")) ==
               "defmodule App, do: def v, do: :updated\n"

      {:ok, %File.Stat{mode: mode}} = File.stat(Path.join(repo, "bin/run.sh"))
      assert Bitwise.band(mode, 0o111) != 0

      # Verify zero leftover temp files in repo or subdir
      assert [] == Path.wildcard(Path.join(repo, "**/.wt-*"))
      assert [] == Path.wildcard(Path.join(repo, "**/.*.wt-*"))
      refute File.dir?(wt.path)
    end

    test "apply_back/3 fails closed before mutating any target file on unsafe symlinks" do
      repo = init_git_repo("wt_symlink_fail")
      base_dir = make_temp_dir("wt_symlink_base")
      outside = make_temp_dir("wt_outside")
      outside_secret = Path.join(outside, "secret.txt")
      File.write!(outside_secret, "do not touch\n")

      # Case 1: Escaping symlink inside worktree fails closed before earlier valid file a_valid.txt is written
      assert {:ok, wt} = Worktree.create(repo, base_dir: base_dir)
      File.write!(Path.join(wt.path, "a_valid.txt"), "should not land\n")
      File.ln_s!(outside_secret, Path.join(wt.path, "z_escape"))

      assert {:error, :outside_workspace} = Worktree.apply_back(wt, repo)
      refute File.exists?(Path.join(repo, "a_valid.txt"))
      assert :ok = Worktree.cleanup(wt)

      # Case 1b: Internal symlink inside worktree also fails closed with :unsafe_symlink
      assert {:ok, wt_int} = Worktree.create(repo, base_dir: base_dir)
      File.write!(Path.join(wt_int.path, "a_valid.txt"), "should not land\n")
      File.ln_s!(Path.join(wt_int.path, "README.md"), Path.join(wt_int.path, "internal_link"))

      assert {:error, {:unsafe_symlink, "internal_link"}} = Worktree.apply_back(wt_int, repo)
      refute File.exists?(Path.join(repo, "a_valid.txt"))
      assert :ok = Worktree.cleanup(wt_int)

      # Case 2: Target workspace directory replaced with escaping symlink fails closed
      target_escape_repo = init_git_repo("wt_target_escape")
      assert {:ok, wt2} = Worktree.create(target_escape_repo, base_dir: base_dir)
      File.write!(Path.join(wt2.path, "a_first.txt"), "new file\n")
      File.write!(Path.join(wt2.path, "lib/app.ex"), "hacked\n")

      # Replace target_escape_repo/lib with symlink to outside dir
      File.rm_rf!(Path.join(target_escape_repo, "lib"))
      File.ln_s!(outside, Path.join(target_escape_repo, "lib"))

      assert {:error, :outside_workspace} = Worktree.apply_back(wt2, target_escape_repo)
      refute File.exists?(Path.join(target_escape_repo, "a_first.txt"))
      assert :ok = Worktree.cleanup(wt2)
    end

    test "apply_back/3 respects WorkspaceLocks contention without partial writes" do
      repo = init_git_repo("wt_locks")
      base_dir = make_temp_dir("wt_locks_base")
      Repo.insert!(%Project{name: "wt-locks-proj", root_path: repo})
      assert {:ok, wt} = Worktree.create(repo, base_dir: base_dir)

      File.write!(Path.join(wt.path, "a_new.txt"), "new file\n")
      File.write!(Path.join(wt.path, "lib/app.ex"), "updated locked\n")

      parent = self()

      {holder_pid, holder_ref} =
        spawn_monitor(fn ->
          receive do
            :acquire ->
              WorkspaceLocks.with_locks(
                repo,
                [{{:file, "lib/app.ex"}, :write}],
                [owner_id: "test-blocker-#{System.unique_integer([:positive])}"],
                fn ->
                  send(parent, :lock_acquired)

                  receive do
                    :release -> :ok
                  end
                end
              )
          end
        end)

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), holder_pid)
      send(holder_pid, :acquire)
      assert_receive :lock_acquired, 2_000

      assert {:error, {:workspace_lock_waiting, _conflicts}} = Worktree.apply_back(wt, repo)
      refute File.exists?(Path.join(repo, "a_new.txt"))
      assert File.read!(Path.join(repo, "lib/app.ex")) == "defmodule App, do: def v, do: 1\n"

      send(holder_pid, :release)
      assert_receive {:DOWN, ^holder_ref, :process, ^holder_pid, :normal}, 2_000

      # Once released, apply_back succeeds cleanly
      assert {:ok, _} = Worktree.apply_back(wt, repo, cleanup: true)
      assert File.read!(Path.join(repo, "a_new.txt")) == "new file\n"
      assert File.read!(Path.join(repo, "lib/app.ex")) == "updated locked\n"
    end

    test "cleanup/2 is idempotent and prune_orphans/2 removes stale metadata and orphaned directories" do
      repo = init_git_repo("wt_prune")
      base_dir = make_temp_dir("wt_prune_base")

      assert {:ok, wt} = Worktree.create(repo, base_dir: base_dir, id: "stale_wt")
      # Simulate abrupt crash where worktree directory disappeared or orphan directory left behind
      File.rm_rf!(wt.path)
      orphan_dir = Path.join(base_dir, "orphan_dir_123")
      File.mkdir_p!(orphan_dir)
      File.write!(Path.join(orphan_dir, "leftover.txt"), "stale")

      assert {:ok, %{pruned_worktrees: pruned, removed_dirs: removed}} =
               Worktree.prune_orphans(repo, base_dir: base_dir)

      assert pruned >= 1
      assert Path.expand(orphan_dir) in Enum.map(removed, &Path.expand/1) or length(removed) >= 1
      refute File.exists?(orphan_dir)

      # Cleanup on already-removed worktree succeeds cleanly (idempotent)
      assert :ok = Worktree.cleanup(wt)
      assert :ok = Worktree.cleanup(wt)
    end
  end
end

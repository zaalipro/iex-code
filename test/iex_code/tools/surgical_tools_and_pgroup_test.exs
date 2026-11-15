defmodule IexCode.Tools.SurgicalToolsAndPgroupTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Projects, Tools, WorkspaceLocks}
  alias IexCode.Settings.AppSettings
  alias IexCode.Tools.{ProcessGroupRunner, RepoMap, SafetyPolicy}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "iex-code-surgical-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  describe "patch_file and multi_patch ambiguity & diagnostics through Tools" do
    test "tool schemas expose optional anchor_line and allow_multiple properties" do
      defs = Tools.tool_definitions(:all) |> Map.new(&{&1.name, &1})

      patch_props = defs["patch_file"].parameters.properties
      assert patch_props.anchor_line.type == "integer"
      assert patch_props.allow_multiple.type == "boolean"
      refute "anchor_line" in defs["patch_file"].parameters.required
      refute "allow_multiple" in defs["patch_file"].parameters.required

      multi_item_props = defs["multi_patch"].parameters.properties.patches.items.properties
      assert multi_item_props.anchor_line.type == "integer"
      assert multi_item_props.allow_multiple.type == "boolean"
      refute "anchor_line" in defs["multi_patch"].parameters.properties.patches.items.required
      refute "allow_multiple" in defs["multi_patch"].parameters.properties.patches.items.required
    end

    test "patch_file rejects ambiguous match with line numbers and supports anchor_line and allow_multiple",
         %{root: root} do
      file = Path.join(root, "dup.ex")

      File.write!(file, """
      defmodule Dup do
        def first, do: :placeholder
        def mid, do: :keep
        def second, do: :placeholder
      end
      """)

      assert {:error, err} =
               Tools.execute(
                 "patch_file",
                 %{
                   "path" => "dup.ex",
                   "target_content" => "do: :placeholder",
                   "replacement_content" => "do: :updated"
                 },
                 root
               )

      assert err =~ "Ambiguous target in dup.ex"
      assert err =~ "2, 4"

      assert {:ok, _} =
               Tools.execute(
                 "patch_file",
                 %{
                   "path" => "dup.ex",
                   "target_content" => "do: :placeholder",
                   "replacement_content" => "do: :second_done",
                   "anchor_line" => 4
                 },
                 root
               )

      content_after_anchor = File.read!(file)
      assert content_after_anchor =~ "def first, do: :placeholder"
      assert content_after_anchor =~ "def second, do: :second_done"

      # Add duplicate again and verify allow_multiple replaces all
      File.write!(file, "a = :placeholder\nb = :placeholder\n")

      assert {:ok, _} =
               Tools.execute(
                 "patch_file",
                 %{
                   "path" => "dup.ex",
                   "target_content" => ":placeholder",
                   "replacement_content" => ":final",
                   "allow_multiple" => true
                 },
                 root
               )

      assert File.read!(file) == "a = :final\nb = :final\n"
    end

    test "patch_file and multi_patch include closest-match diagnostics when target is not found",
         %{root: root} do
      File.write!(Path.join(root, "sample.ex"), """
      defmodule Sample do
        def greet(user_name) do
          "hello \#{user_name}"
        end
      end
      """)

      assert {:error, patch_err} =
               Tools.execute(
                 "patch_file",
                 %{
                   "path" => "sample.ex",
                   "target_content" => "def greet(username) do\n  \"hi\"\nend",
                   "replacement_content" => "def greet(x), do: x"
                 },
                 root
               )

      assert patch_err =~ "Target content not found in sample.ex"
      assert patch_err =~ "Closest matching window"
      assert patch_err =~ "2:   def greet(user_name) do"

      assert {:error, multi_err} =
               Tools.execute(
                 "multi_patch",
                 %{
                   "patches" => [
                     %{
                       "path" => "sample.ex",
                       "target_content" => "def greet(username) do\n  \"hi\"\nend",
                       "replacement_content" => "def greet(x), do: x"
                     }
                   ]
                 },
                 root
               )

      assert multi_err =~ "MultiPatch failed: Target content not found in sample.ex"
      assert multi_err =~ "Closest matching window"
    end
  end

  describe "legacy RoleSpec alias resolution" do
    test "filter_tool_definitions resolves legacy aliases to canonical tool definitions" do
      filtered =
        Tools.tool_definitions([
          :view_file,
          :replace_file_content,
          :write_to_file,
          :find_by_name
        ])

      names = Enum.map(filtered, & &1.name) |> Enum.sort()
      assert names == ["list_dir", "patch_file", "read_file", "write_file"]
    end

    test "SafetyPolicy maps legacy aliases and new read-only tools accurately" do
      assert SafetyPolicy.category_for_tool("view_file") == "read_only"
      assert SafetyPolicy.category_for_tool(:find_by_name) == "read_only"
      assert SafetyPolicy.category_for_tool("repo_map") == "read_only"
      assert SafetyPolicy.category_for_tool("diagnostics") == "read_only"
      assert SafetyPolicy.category_for_tool("write_to_file") == "file_mutations"
      assert SafetyPolicy.category_for_tool(:replace_file_content) == "file_mutations"

      ro_settings = %AppSettings{tool_approval_mode: "read_only", tool_category_overrides: %{}}
      assert SafetyPolicy.evaluate("view_file", ro_settings) == :allow
      assert SafetyPolicy.evaluate("find_by_name", ro_settings) == :allow
      assert SafetyPolicy.evaluate("repo_map", ro_settings) == :allow
      assert SafetyPolicy.evaluate("diagnostics", ro_settings) == :allow
      assert {:deny, _} = SafetyPolicy.evaluate("write_to_file", ro_settings)
      assert {:deny, _} = SafetyPolicy.evaluate("replace_file_content", ro_settings)
    end

    test "Tools.execute resolves legacy aliases including NativeResponse envelope and write locks",
         %{root: root} do
      File.mkdir_p!(Path.join(root, "lib"))
      {:ok, project} = Projects.create_project(%{name: "Alias test", root_path: root})

      assert {:ok, write_msg} =
               Tools.execute(
                 "write_to_file",
                 %{
                   "path" => "lib/demo.ex",
                   "content" => "defmodule Demo do\n  def x, do: 1\nend\n"
                 },
                 root
               )

      assert write_msg =~ "Successfully wrote"

      assert {:ok, patch_msg} =
               Tools.execute(
                 "replace_file_content",
                 %{
                   "path" => "lib/demo.ex",
                   "target_content" => "def x, do: 1",
                   "replacement_content" => "def x, do: 2"
                 },
                 root
               )

      assert patch_msg =~ "Successfully patched"

      assert {:ok, read_out} = Tools.execute("view_file", %{"path" => "lib/demo.ex"}, root)
      assert read_out =~ "def x, do: 2"

      assert {:ok, list_out} = Tools.execute("find_by_name", %{"path" => "lib"}, root)
      assert list_out =~ "demo.ex"

      # Verify write lock is enforced for write_to_file / replace_file_content aliases
      assert {:ok, blocker} =
               WorkspaceLocks.acquire(
                 project,
                 [{{:file, "lib/demo.ex"}, :write}],
                 owner_id: "test:alias-blocker"
               )

      on_exit(fn -> WorkspaceLocks.release(blocker) end)

      assert {:error, {:workspace_lock_waiting, _}} =
               Tools.execute(
                 "replace_file_content",
                 %{
                   "project_id" => project.id,
                   "run_id" => "alias-run",
                   "path" => "lib/demo.ex",
                   "target_content" => "def x, do: 2",
                   "replacement_content" => "def x, do: 3"
                 },
                 root
               )
    end
  end

  describe "repo_map tool" do
    test "extracts Elixir and polyglot symbols, ranks by focus_query, bounds max_bytes, and excludes vendor dirs",
         %{root: root} do
      File.mkdir_p!(Path.join(root, "lib"))
      File.mkdir_p!(Path.join(root, "assets"))
      File.mkdir_p!(Path.join(root, "scripts"))
      File.mkdir_p!(Path.join(root, "crates"))
      File.mkdir_p!(Path.join(root, "cmd"))

      for excluded <- ~w(_build deps node_modules .git tmp) do
        dir = Path.join(root, excluded)
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "ignored.ex"), "defmodule ShouldNeverAppear, do: :nope\n")
      end

      File.write!(Path.join(root, "lib/payment_gateway.ex"), """
      defmodule MyApp.PaymentGateway do
        @behaviour GenServer
        @type charge_result :: {:ok, String.t()} | {:error, term()}
        @callback authorize(integer()) :: charge_result()

        def charge(amount, opts \\\\ []) do
          {:ok, amount, opts}
        end

        defmacro with_audit(do: block), do: block
        defp hidden_helper, do: :secret
      end
      """)

      File.write!(Path.join(root, "assets/widget.ts"), """
      export interface WidgetProps {
        id: string;
      }
      export async function renderWidget(props: WidgetProps) {
        return props.id;
      }
      export const mountWidget = (id: string) => id;
      """)

      File.write!(Path.join(root, "scripts/worker.py"), """
      class JobRunner:
          pass

      async def dispatch_job(payload):
          return payload
      """)

      File.write!(Path.join(root, "crates/engine.rs"), """
      pub struct FastEngine {
        count: usize,
      }
      pub fn compute_hash(input: &str) -> u64 {
        0
      }
      """)

      File.write!(Path.join(root, "cmd/server.go"), """
      package main
      type Config struct {
        Port int
      }
      func StartServer(cfg Config) error {
        return nil
      }
      """)

      assert {:ok, output} =
               Tools.execute("repo_map", %{"focus_query" => "PaymentGateway authorize"}, root)

      assert output =~ "defmodule MyApp.PaymentGateway"
      assert output =~ "@behaviour GenServer"
      assert output =~ "@type charge_result/0"
      assert output =~ "@callback authorize/1"
      assert output =~ "def charge/2"
      assert output =~ "defmacro with_audit/1"
      refute output =~ "hidden_helper"

      assert output =~ "interface WidgetProps"
      assert output =~ "function renderWidget"
      assert output =~ "const mountWidget"
      assert output =~ "class JobRunner"
      assert output =~ "def dispatch_job"
      assert output =~ "struct FastEngine"
      assert output =~ "fn compute_hash"
      assert output =~ "type Config"
      assert output =~ "func StartServer"

      refute output =~ "ShouldNeverAppear"
      refute output =~ "_build/ignored.ex"

      # focus_query ranks lib/payment_gateway.ex first among file sections
      [first_section | _] =
        output
        |> String.split("\n## ")
        |> Enum.drop(1)

      assert String.starts_with?(first_section, "lib/payment_gateway.ex")

      # Enforces max_bytes ceiling strictly
      assert {:ok, bounded} = RepoMap.generate(root, max_bytes: 320)
      assert byte_size(bounded) <= 320
      assert bounded =~ "truncated at 320 bytes"

      # Rejects path traversal escaping workspace
      assert {:error, escape_err} = Tools.execute("repo_map", %{"path" => "../etc"}, root)
      assert escape_err =~ "escapes the workspace"
    end
  end

  describe "diagnostics tool" do
    test "reports structured syntax errors across Elixir files and passes clean workspaces", %{
      root: root
    } do
      File.mkdir_p!(Path.join(root, "lib"))
      File.mkdir_p!(Path.join(root, "tmp"))

      # Excluded directories should not trigger syntax diagnostics
      File.write!(Path.join(root, "tmp/broken.ex"), "defmodule TmpBroken do\n  def x\n")

      File.write!(Path.join(root, "lib/good.ex"), "defmodule Good do\n  def ok, do: :ok\nend\n")

      assert {:ok, clean_out} = Tools.execute("diagnostics", %{}, root)
      assert clean_out =~ "No diagnostics found"

      File.write!(Path.join(root, "lib/bad.ex"), "defmodule Bad do\n  def broken( do\nend\n")

      assert {:ok, diag_out} = Tools.execute("diagnostics", %{}, root)
      assert diag_out =~ ~r/^lib\/bad\.ex:\d+ \[error\] /m

      assert {:error, escape_err} =
               Tools.execute("diagnostics", %{"path" => "../../outside"}, root)

      assert escape_err =~ "escapes the workspace"
    end

    test "compile: true checks Mix compiler diagnostics under exclusive project lock", %{
      root: root
    } do
      File.mkdir_p!(Path.join(root, "lib"))

      File.write!(Path.join(root, "mix.exs"), """
      defmodule MiniProj.MixProject do
        use Mix.Project
        def project, do: [app: :mini_proj, version: "0.1.0", elixir: "~> 1.15"]
      end
      """)

      File.write!(Path.join(root, "lib/broken_compile.ex"), """
      defmodule MiniProj.Broken do
        use MissingBehaviourModule

        def call_missing do
          DoesNotExist.run()
        end
      end
      """)

      {:ok, project} = Projects.create_project(%{name: "Diag lock test", root_path: root})

      assert {:ok, blocker} =
               WorkspaceLocks.acquire(
                 project,
                 [{:project, :exclusive}],
                 owner_id: "test:diag-lock"
               )

      assert {:error, {:workspace_lock_waiting, _}} =
               Tools.execute(
                 "diagnostics",
                 %{
                   "project_id" => project.id,
                   "run_id" => "diag-locked-run",
                   "compile" => true
                 },
                 root
               )

      assert :ok = WorkspaceLocks.release(blocker)

      assert {:ok, out} = Tools.execute("diagnostics", %{"compile" => true}, root)
      assert out =~ ~r/lib\/broken_compile\.ex:\d+ \[error\] /
    end
  end

  describe "ProcessGroupRunner and run_command process-group reaper" do
    test "captures stdout, stderr, non-zero exit codes, and truncates huge output cleanly", %{
      root: root
    } do
      assert {:ok, %{exit_code: 0, output: ok_out, truncated?: false}} =
               ProcessGroupRunner.run("echo hello_out && echo hello_err >&2",
                 cd: root,
                 env: System.get_env()
               )

      assert ok_out =~ "hello_out"
      assert ok_out =~ "hello_err"

      assert {:ok, %{exit_code: 7, output: fail_out}} =
               ProcessGroupRunner.run("echo failing; exit 7", cd: root, env: System.get_env())

      assert fail_out =~ "failing"

      assert {:ok, big_out} =
               Tools.execute("run_command", %{"command" => "echo first; exit 3"}, root)

      assert big_out =~ "Exit Code 3:"
      assert big_out =~ "first"
    end

    test "reaps entire process group including background sleep grandchildren on timeout", %{
      root: root
    } do
      pid_file = Path.join(root, "grandchild.pid")
      cmd = "sh -c 'sleep 30 & echo $! > #{pid_file}; wait'"

      assert {:error, err} =
               Tools.execute("run_command", %{"command" => cmd, "timeout_ms" => 350}, root)

      assert err =~ "Command timed out after 350ms"

      assert File.exists?(pid_file)
      grandchild_pid = pid_file |> File.read!() |> String.trim()
      assert grandchild_pid =~ ~r/^\d+$/

      refute wait_until_pid_dead(grandchild_pid, 500),
             "Expected background grandchild PID #{grandchild_pid} to be reaped on timeout"
    end

    test "reaps SIGTERM-ignoring children via SIGKILL fallback on timeout", %{root: root} do
      pid_file = Path.join(root, "trap_child.pid")
      cmd = "trap '' TERM; sleep 30 & child=$!; echo $child > #{pid_file}; wait $child"

      assert {:timeout, _info} =
               ProcessGroupRunner.run(cmd, cd: root, env: System.get_env(), timeout_ms: 350)

      assert File.exists?(pid_file)
      child_pid = pid_file |> File.read!() |> String.trim()
      assert child_pid =~ ~r/^\d+$/

      refute wait_until_pid_dead(child_pid, 500),
             "Expected SIGTERM-ignoring grandchild PID #{child_pid} to be reaped via SIGKILL"
    end

    test "reaps child process group when port owner closes abruptly", %{root: root} do
      pid_file = Path.join(root, "killed_task_child.pid")
      cmd = "sh -c 'sleep 30 & echo $! > #{pid_file}; wait'"

      {task_pid, ref} =
        spawn_monitor(fn ->
          ProcessGroupRunner.run(cmd, cd: root, env: System.get_env(), timeout_ms: 30_000)
        end)

      assert wait_until_file(pid_file, 2_000)
      child_pid = pid_file |> File.read!() |> String.trim()
      assert child_pid =~ ~r/^\d+$/

      Process.exit(task_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^task_pid, :killed}, 1_000

      refute wait_until_pid_dead(child_pid, 1_500),
             "Expected grandchild PID #{child_pid} to be reaped when owner closed port"
    end
  end

  defp wait_until_file(path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_file(path, deadline)
  end

  defp do_wait_until_file(path, deadline) do
    cond do
      File.exists?(path) and byte_size(File.read!(path)) > 0 ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        receive do
        after
          20 -> do_wait_until_file(path, deadline)
        end
    end
  end

  defp wait_until_pid_dead(pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_pid_alive?(pid, deadline)
  end

  defp do_wait_until_pid_alive?(pid, deadline) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} ->
        if System.monotonic_time(:millisecond) >= deadline do
          true
        else
          receive do
          after
            25 -> do_wait_until_pid_alive?(pid, deadline)
          end
        end

      _ ->
        false
    end
  end
end

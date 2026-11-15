defmodule IexCode.Tools.SymbolRefactorTest do
  use ExUnit.Case, async: true

  alias IexCode.Tools.SymbolRefactor

  describe "find_references/3 — module symbols" do
    @tag :tmp_dir
    test "classifies all module reference kinds accurately and resolves aliases without matching comments/strings/heredocs",
         %{tmp_dir: tmp_dir} do
      lib_dir = Path.join(tmp_dir, "lib/my_app")
      File.mkdir_p!(lib_dir)

      # 1. Definition + typespec + struct + comments/heredocs/strings
      File.write!(Path.join(lib_dir, "legacy_worker.ex"), """
      defmodule MyApp.LegacyWorker do
        @moduledoc \"\"\"
        Documentation mentioning MyApp.LegacyWorker and LegacyWorker.run(1) inside heredoc.
        \"\"\"
        # Comment mentioning MyApp.LegacyWorker and %MyApp.LegacyWorker{}

        defstruct [:id, :status]
        @type t :: %MyApp.LegacyWorker{id: integer(), status: atom()}

        @callback handle_job(t()) :: :ok

        @doc "Runs MyApp.LegacyWorker job"
        def run(x), do: {:ok, x, "MyApp.LegacyWorker string literal"}
        def run(x, y), do: {:ok, x + y, ~s(MyApp.LegacyWorker sigil)}
      end
      """)

      # 2. Multi-alias, import, require, use, struct, call, capture, spec_or_type, module_ref
      File.write!(Path.join(lib_dir, "consumer_a.ex"), """
      defmodule MyApp.ConsumerA do
        alias MyApp.{LegacyWorker, OtherService}
        import MyApp.LegacyWorker, only: [run: 2]
        require MyApp.LegacyWorker
        use MyApp.LegacyWorker

        @behaviour MyApp.LegacyWorker
        @spec execute(LegacyWorker.t()) :: {:ok, term(), String.t()}
        def execute(%LegacyWorker{} = worker) do
          fun = &LegacyWorker.run/1
          _res = LegacyWorker.run(worker.id)
          _sup = Supervisor.child_spec(LegacyWorker, [])
          fun.(worker.id)
        end
      end
      """)

      # 3. Custom `:as` alias + sibling module lexical isolation
      File.write!(Path.join(lib_dir, "consumer_b.ex"), """
      defmodule MyApp.ConsumerB do
        alias MyApp.LegacyWorker, as: CustomWorker

        def process(id) do
          s = %CustomWorker{id: id}
          cap = &CustomWorker.run(&1)
          {CustomWorker.run(s.id), cap}
        end
      end

      defmodule MyApp.SiblingIsolated do
        # CustomWorker is NOT aliased in this sibling module!
        alias OtherPkg.CustomWorker

        def unrelated(id) do
          CustomWorker.run(id)
        end
      end
      """)

      assert {:ok, refs} = SymbolRefactor.find_references(tmp_dir, "MyApp.LegacyWorker")

      # Atom module spec produces identical results
      assert {:ok, ^refs} = SymbolRefactor.find_references(tmp_dir, MyApp.LegacyWorker)

      kinds = MapSet.new(Enum.map(refs, & &1.kind))

      assert :definition in kinds
      assert :alias in kinds
      assert :import in kinds
      assert :require in kinds
      assert :use in kinds
      assert :struct in kinds
      assert :call in kinds
      assert :capture in kinds
      assert :spec_or_type in kinds
      assert :module_ref in kinds

      # Verify sibling module's `OtherPkg.CustomWorker` was NOT matched
      refute Enum.any?(refs, fn r ->
               r.file == "lib/my_app/consumer_b.ex" and r.line >= 11
             end)

      # Verify comments, @moduledoc/@doc heredocs, string literals, and sigils were NEVER matched
      refute Enum.any?(refs, fn r ->
               r.file == "lib/my_app/legacy_worker.ex" and r.line in [2, 3, 4, 5, 12, 13, 14]
             end)

      # Every reference has valid metadata
      Enum.each(refs, fn ref ->
        assert is_binary(ref.file)
        assert is_integer(ref.line) and ref.line >= 1
        assert is_integer(ref.column) and ref.column >= 1
        assert is_binary(ref.snippet) and ref.snippet != ""
      end)
    end
  end

  describe "find_references/3 — function & macro symbols" do
    @tag :tmp_dir
    test "resolves arity, pipelines, aliases, imports, captures, and default args while ignoring map fields and unrelated modules",
         %{tmp_dir: tmp_dir} do
      lib_dir = Path.join(tmp_dir, "lib/my_app")
      File.mkdir_p!(lib_dir)

      File.write!(Path.join(lib_dir, "worker.ex"), """
      defmodule MyApp.Worker do
        # Comment: MyApp.Worker.run(1, 2)
        @spec run(integer()) :: integer()
        def run(a), do: a

        @spec run(integer(), integer()) :: integer()
        def run(a, b) when is_integer(a) do
          # Recursive local call + local pipeline + local capture
          f = &run/2
          res = a |> run(b)
          f.(res, run(1, 2))
        end

        def status, do: :ready

        def check_status do
          # Zero-arity local call (matches status/0):
          s1 = status
          # Shadowed local variable `status` (must NOT match status/0):
          status = :busy
          {s1, status}
        end
      end
      """)

      File.write!(Path.join(lib_dir, "caller.ex"), """
      defmodule MyApp.Caller do
        alias MyApp.Worker
        alias MyApp.Worker, as: W

        def invoke(state) do
          _str = "MyApp.Worker.run(1, 2)"
          _atom = :run
          _field = state.run
          _one_arity = Worker.run(10)
          _one_cap = &Worker.run/1

          a = MyApp.Worker.run(1, 2)
          b = Worker.run(3, 4)
          c = 5 |> W.run(6)
          cap = &W.run/2
          {a, b, c, cap}
        end
      end

      defmodule MyApp.ImportedCaller do
        import MyApp.Worker, only: [run: 2]

        def go(x), do: run(x, 10)
      end

      defmodule MyApp.Unrelated do
        def run(a, b), do: {a, b}
        def call_local, do: run(1, 2)
      end
      """)

      # Exact arity 2 via string spec and tuple spec
      assert {:ok, refs_2} = SymbolRefactor.find_references(tmp_dir, "MyApp.Worker.run/2")

      assert {:ok, ^refs_2} =
               SymbolRefactor.find_references(tmp_dir, {MyApp.Worker, :run, 2})

      # Unrelated module's `run/2` must NEVER match
      refute Enum.any?(refs_2, fn r ->
               r.file == "lib/my_app/caller.ex" and r.line >= 26
             end)

      # 1-arity definition/calls, comments, string literals, atoms, and `state.run` must NEVER match `run/2`
      refute Enum.any?(refs_2, fn r ->
               r.file == "lib/my_app/worker.ex" and r.line in [2, 3, 4]
             end)

      refute Enum.any?(refs_2, fn r ->
               r.file == "lib/my_app/caller.ex" and r.line in [6, 7, 8, 9, 10]
             end)

      # Verify expected kinds for `run/2`
      kinds_2 = Enum.map(refs_2, & &1.kind)
      assert :spec_or_type in kinds_2
      assert :definition in kinds_2
      assert :capture in kinds_2
      assert :call in kinds_2
      assert :import in kinds_2

      # Wildcard `:any` arity finds BOTH `run/1` and `run/2`
      assert {:ok, refs_any} = SymbolRefactor.find_references(tmp_dir, "MyApp.Worker.run")
      assert length(refs_any) > length(refs_2)

      # Zero-arity `status/0` matches `def status` and `s1 = status`, NOT shadowed variable `status = :busy`
      assert {:ok, status_refs} = SymbolRefactor.find_references(tmp_dir, "MyApp.Worker.status/0")
      status_lines = Enum.map(status_refs, & &1.line)
      assert 14 in status_lines
      assert 18 in status_lines
      refute 20 in status_lines
      refute 21 in status_lines
    end
  end

  describe "rename_symbol/4 — module refactoring" do
    @tag :tmp_dir
    test "renames module across workspace including multi-alias update & cross-namespace expansion while preserving comments and strings",
         %{tmp_dir: tmp_dir} do
      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)

      mod_file = Path.join(lib_dir, "old_mod.ex")
      same_ns_caller = Path.join(lib_dir, "same_ns_caller.ex")
      custom_alias_caller = Path.join(lib_dir, "custom_alias_caller.ex")

      File.write!(mod_file, """
      defmodule MyApp.OldMod do
        @moduledoc \"\"\"
        Keep MyApp.OldMod untouched in moduledoc!
        \"\"\"
        # Keep MyApp.OldMod untouched in comments!
        defstruct [:name]
        @type t :: %MyApp.OldMod{name: String.t()}

        def greet(%MyApp.OldMod{name: n}) do
          "café from MyApp.OldMod: " <> n
        end
      end
      """)

      File.write!(same_ns_caller, """
      defmodule MyApp.SameNsCaller do
        alias MyApp.{OldMod, OtherHelper}
        use MyApp.OldMod
        import MyApp.OldMod
        require MyApp.OldMod
        @behaviour MyApp.OldMod

        @spec run(OldMod.t()) :: String.t()
        def run(%OldMod{} = item) do
          fn_ref = &OldMod.greet/1
          _direct = MyApp.OldMod.greet(item)
          fn_ref.(item)
        end
      end
      """)

      File.write!(custom_alias_caller, """
      defmodule MyApp.CustomCaller do
        alias MyApp.OldMod, as: SpecialAlias

        def call_it(n) do
          s = %SpecialAlias{name: n}
          SpecialAlias.greet(s)
        end
      end
      """)

      # Step 1: Same-namespace rename `MyApp.OldMod` -> `MyApp.NewMod`
      assert {:ok, res1} =
               SymbolRefactor.rename_symbol(tmp_dir, "MyApp.OldMod", "MyApp.NewMod")

      assert res1.dry_run == false
      assert res1.files_changed == 3
      assert res1.occurrences >= 12
      assert res1.diff =~ "--- a/lib/old_mod.ex"
      assert res1.diff =~ "+++ b/lib/old_mod.ex"

      mod_after_1 = File.read!(mod_file)
      assert mod_after_1 =~ "defmodule MyApp.NewMod do"
      assert mod_after_1 =~ "@type t :: %MyApp.NewMod{name: String.t()}"
      assert mod_after_1 =~ "def greet(%MyApp.NewMod{name: n}) do"
      # Untouched comments, moduledoc, and string literals!
      assert mod_after_1 =~ "Keep MyApp.OldMod untouched in moduledoc!"
      assert mod_after_1 =~ "# Keep MyApp.OldMod untouched in comments!"
      assert mod_after_1 =~ ~s("café from MyApp.OldMod: " <> n)

      caller_after_1 = File.read!(same_ns_caller)
      assert caller_after_1 =~ "alias MyApp.{NewMod, OtherHelper}"
      assert caller_after_1 =~ "use MyApp.NewMod"
      assert caller_after_1 =~ "import MyApp.NewMod"
      assert caller_after_1 =~ "require MyApp.NewMod"
      assert caller_after_1 =~ "@behaviour MyApp.NewMod"
      assert caller_after_1 =~ "@spec run(NewMod.t()) :: String.t()"
      assert caller_after_1 =~ "def run(%NewMod{} = item) do"
      assert caller_after_1 =~ "fn_ref = &NewMod.greet/1"
      assert caller_after_1 =~ "_direct = MyApp.NewMod.greet(item)"

      custom_after_1 = File.read!(custom_alias_caller)
      assert custom_after_1 =~ "alias MyApp.NewMod, as: SpecialAlias"
      assert custom_after_1 =~ "%SpecialAlias{name: n}"
      assert custom_after_1 =~ "SpecialAlias.greet(s)"

      # Step 2: Cross-namespace rename `MyApp.NewMod` -> `CoreEngine.RenamedWorker`
      # Verifies multi-alias `{NewMod, OtherHelper}` expands cleanly!
      assert {:ok, res2} =
               SymbolRefactor.rename_symbol(
                 tmp_dir,
                 "MyApp.NewMod",
                 "CoreEngine.RenamedWorker"
               )

      assert res2.files_changed == 3

      caller_after_2 = File.read!(same_ns_caller)
      assert caller_after_2 =~ "alias MyApp.OtherHelper\n  alias CoreEngine.RenamedWorker"
      assert caller_after_2 =~ "@spec run(RenamedWorker.t()) :: String.t()"
      assert caller_after_2 =~ "def run(%RenamedWorker{} = item) do"
      assert caller_after_2 =~ "fn_ref = &RenamedWorker.greet/1"
      assert caller_after_2 =~ "_direct = CoreEngine.RenamedWorker.greet(item)"

      for f <- [mod_file, same_ns_caller, custom_alias_caller] do
        assert {:ok, _} = Code.string_to_quoted(File.read!(f))
      end
    end
  end

  describe "rename_symbol/4 — function refactoring" do
    @tag :tmp_dir
    test "renames function of specific arity across def/defp/defdelegate/@spec, local, qualified, aliased, piped, and captured calls",
         %{tmp_dir: tmp_dir} do
      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)

      worker_file = Path.join(lib_dir, "worker.ex")
      delegator_file = Path.join(lib_dir, "delegator.ex")
      caller_file = Path.join(lib_dir, "caller.ex")

      File.write!(worker_file, """
      defmodule MyApp.Worker do
        # Comment with old_fun(1, 2) must stay untouched
        @doc "Doc mentioning old_fun(a, b)"
        @spec old_fun(integer()) :: integer()
        def old_fun(a), do: a * 2

        @spec old_fun(integer(), integer()) :: integer()
        def old_fun(a, b \\\\ 0)
        def old_fun(0, b), do: b

        def old_fun(a, b) when a > 0 do
          "café old_fun(1, 2)"
          local_cap = &old_fun/2
          piped = (a - 1) |> old_fun(b + 1)
          local_cap.(piped, old_fun(0, 1))
        end

        defp helper(x), do: old_fun(x, 5)
      end
      """)

      File.write!(delegator_file, """
      defmodule MyApp.Delegator do
        defdelegate delegated_call(a, b), to: MyApp.Worker, as: :old_fun
      end

      defmodule MyApp.DirectDelegate do
        defdelegate old_fun(a, b), to: OtherBackend
      end
      """)

      File.write!(caller_file, """
      defmodule MyApp.Caller do
        alias MyApp.Worker
        alias MyApp.Worker, as: W
        import MyApp.Worker, only: [old_fun: 2]

        def execute(x) do
          r1 = MyApp.Worker.old_fun(x, 1)
          r2 = Worker.old_fun(x, 2)
          r3 = x |> W.old_fun(3)
          r4 = old_fun(x, 4)
          c1 = &MyApp.Worker.old_fun/2
          c2 = &Worker.old_fun(&1, 2)
          # 1-arity call (NOTE: old_fun(a, b \\\\ 0) header has default arg, let's also check 3-arity untouched!)
          {r1, r2, r3, r4, c1, c2}
        end
      end
      """)

      # Also test `defdelegate` inside the target module itself
      assert {:ok, _} =
               SymbolRefactor.rename_symbol(
                 tmp_dir,
                 "MyApp.DirectDelegate.old_fun/2",
                 "new_delegate_fun"
               )

      assert File.read!(delegator_file) =~ "defdelegate new_delegate_fun(a, b), to: OtherBackend"

      # Rename `MyApp.Worker.old_fun/2` -> `compute_sum`
      assert {:ok, result} =
               SymbolRefactor.rename_symbol(tmp_dir, "MyApp.Worker.old_fun/2", "compute_sum")

      assert result.dry_run == false
      assert result.files_changed == 3

      worker_after = File.read!(worker_file)
      # 1-arity @spec and def old_fun(a) remain untouched!
      assert worker_after =~ "@spec old_fun(integer()) :: integer()"
      assert worker_after =~ "def old_fun(a), do: a * 2"
      # 2-arity @spec, header, clauses, recursive calls, and local capture are updated!
      assert worker_after =~ "@spec compute_sum(integer(), integer()) :: integer()"
      assert worker_after =~ "def compute_sum(a, b \\\\ 0)"
      assert worker_after =~ "def compute_sum(0, b), do: b"
      assert worker_after =~ "def compute_sum(a, b) when a > 0 do"
      assert worker_after =~ "local_cap = &compute_sum/2"
      assert worker_after =~ "piped = (a - 1) |> compute_sum(b + 1)"
      assert worker_after =~ "local_cap.(piped, compute_sum(0, 1))"
      assert worker_after =~ "defp helper(x), do: compute_sum(x, 5)"
      # Comments, @doc, and string literal untouched!
      assert worker_after =~ "# Comment with old_fun(1, 2) must stay untouched"
      assert worker_after =~ ~s|@doc "Doc mentioning old_fun(a, b)"|
      assert worker_after =~ ~s|"café old_fun(1, 2)"|

      delegator_after = File.read!(delegator_file)

      assert delegator_after =~
               "defdelegate delegated_call(a, b), to: MyApp.Worker, as: :compute_sum"

      caller_after = File.read!(caller_file)
      assert caller_after =~ "import MyApp.Worker, only: [compute_sum: 2]"
      assert caller_after =~ "r1 = MyApp.Worker.compute_sum(x, 1)"
      assert caller_after =~ "r2 = Worker.compute_sum(x, 2)"
      assert caller_after =~ "r3 = x |> W.compute_sum(3)"
      assert caller_after =~ "r4 = compute_sum(x, 4)"
      assert caller_after =~ "c1 = &MyApp.Worker.compute_sum/2"
      assert caller_after =~ "c2 = &Worker.compute_sum(&1, 2)"

      for f <- [worker_file, delegator_file, caller_file] do
        assert {:ok, _} = Code.string_to_quoted(File.read!(f))
      end
    end
  end

  describe "dry_run, syntax validation abort, containment, and rollback safety" do
    @tag :tmp_dir
    test "dry_run: true returns unified diff and counts without modifying disk", %{
      tmp_dir: tmp_dir
    } do
      file_a = Path.join(tmp_dir, "a.ex")
      file_b = Path.join(tmp_dir, "b.ex")

      orig_a = "defmodule Demo.Alpha do\n  def old_op(x), do: x + 1\nend\n"
      orig_b = "defmodule Demo.Beta do\n  def call(x), do: Demo.Alpha.old_op(x)\nend\n"

      File.write!(file_a, orig_a)
      File.write!(file_b, orig_b)

      assert {:ok, preview} =
               SymbolRefactor.rename_symbol(
                 tmp_dir,
                 "Demo.Alpha.old_op/1",
                 "new_op",
                 dry_run: true
               )

      assert preview.dry_run == true
      assert preview.files_changed == 2
      assert preview.occurrences == 2
      assert preview.diff =~ "-  def old_op(x), do: x + 1"
      assert preview.diff =~ "+  def new_op(x), do: x + 1"
      assert preview.diff =~ "-  def call(x), do: Demo.Alpha.old_op(x)"
      assert preview.diff =~ "+  def call(x), do: Demo.Alpha.new_op(x)"
      assert length(preview.changes) == 2

      # Files on disk MUST remain completely untouched
      assert File.read!(file_a) == orig_a
      assert File.read!(file_b) == orig_b
    end

    @tag :tmp_dir
    test "aborts with {:error, {:invalid_transformed_syntax, details}} and zero disk writes if any file becomes syntactically invalid",
         %{tmp_dir: tmp_dir} do
      file_1 = Path.join(tmp_dir, "first.ex")
      file_2 = Path.join(tmp_dir, "second.ex")

      # Notice: `&Demo.Mod.and/2` in `first.ex` IS valid Elixir capture syntax,
      # whereas `def and(a, b)` in `second.ex` is a syntax error!
      # This exercises true multi-file pre-write validation: `first.ex` MUST NOT be written!
      orig_1 = "defmodule Demo.Caller do\n  def cap, do: &Demo.Mod.combine/2\nend\n"
      orig_2 = "defmodule Demo.Mod do\n  def combine(a, b), do: {a, b}\nend\n"

      File.write!(file_1, orig_1)
      File.write!(file_2, orig_2)

      assert {:error, {:invalid_transformed_syntax, details}} =
               SymbolRefactor.rename_symbol(tmp_dir, "Demo.Mod.combine/2", "and")

      assert details.file == "second.ex"
      assert File.read!(file_1) == orig_1
      assert File.read!(file_2) == orig_2

      # Syntax-corrupting module rename also aborts with zero writes
      assert {:error, {:invalid_transformed_syntax, mod_details}} =
               SymbolRefactor.rename_symbol(tmp_dir, "Demo.Mod", "Demo.Bad(Mod")

      assert is_binary(mod_details.file)
      assert File.read!(file_1) == orig_1
      assert File.read!(file_2) == orig_2
    end

    @tag :tmp_dir
    test "enforces WorkspacePath containment, skips excluded dirs, escaping symlinks, and oversized files",
         %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "ws")
      outside = Path.join(tmp_dir, "outside")
      File.mkdir_p!(Path.join(workspace, "lib"))
      File.mkdir_p!(Path.join(workspace, "deps/pkg"))
      File.mkdir_p!(Path.join(workspace, "_build/dev"))
      File.mkdir_p!(outside)

      in_file = Path.join(workspace, "lib/target.ex")
      dep_file = Path.join(workspace, "deps/pkg/dep.ex")
      build_file = Path.join(workspace, "_build/dev/built.ex")
      big_file = Path.join(workspace, "lib/oversized.ex")
      out_file = Path.join(outside, "external.ex")

      File.write!(in_file, "defmodule Scoped.Mod do\n  def act, do: :ok\nend\n")
      orig_dep = "defmodule DepUser do\n  def f, do: Scoped.Mod.act()\nend\n"
      orig_out = "defmodule OutUser do\n  def f, do: Scoped.Mod.act()\nend\n"

      orig_big =
        "defmodule BigUser do\n" <>
          String.duplicate("# pad\n", 100) <> "def f, do: Scoped.Mod.act()\nend\n"

      File.write!(dep_file, orig_dep)
      File.write!(build_file, orig_dep)
      File.write!(big_file, orig_big)
      File.write!(out_file, orig_out)

      # Symlink escaping workspace
      File.ln_s!(out_file, Path.join(workspace, "lib/escape.ex"))
      File.ln_s!(outside, Path.join(workspace, "lib/escape_dir"))

      # Rejects path escaping workspace
      assert {:error, :outside_workspace} =
               SymbolRefactor.find_references(workspace, "Scoped.Mod", path: "../outside")

      assert {:error, :outside_workspace} =
               SymbolRefactor.rename_symbol(workspace, "Scoped.Mod", "Scoped.NewMod",
                 path: "../outside"
               )

      # Finds ONLY `lib/target.ex` when max_file_bytes excludes `big_file`
      assert {:ok, refs} =
               SymbolRefactor.find_references(workspace, "Scoped.Mod", max_file_bytes: 200)

      assert Enum.map(refs, & &1.file) == ["lib/target.ex"]

      # Renames ONLY `lib/target.ex`; external symlink target, deps, _build, and oversized file stay untouched!
      assert {:ok, res} =
               SymbolRefactor.rename_symbol(workspace, "Scoped.Mod", "Scoped.Renamed",
                 max_file_bytes: 200
               )

      assert res.files_changed == 1
      assert File.read!(in_file) =~ "defmodule Scoped.Renamed do"
      assert File.read!(out_file) == orig_out
      assert File.read!(dep_file) == orig_dep
      assert File.read!(big_file) == orig_big
    end

    @tag :tmp_dir
    test "rolls back earlier written files atomically if a subsequent file write fails", %{
      tmp_dir: tmp_dir
    } do
      dir_a = Path.join(tmp_dir, "lib/a")
      dir_b = Path.join(tmp_dir, "lib/b")
      File.mkdir_p!(dir_a)
      File.mkdir_p!(dir_b)

      file_a = Path.join(dir_a, "first.ex")
      file_b = Path.join(dir_b, "second.ex")

      orig_a = "defmodule Rollback.Target do\n  def ping, do: :pong\nend\n"
      orig_b = "defmodule Rollback.Caller do\n  def call, do: Rollback.Target.ping()\nend\n"

      File.write!(file_a, orig_a)
      File.write!(file_b, orig_b)

      # Make `dir_b` read-only so writing the temp sibling file in `dir_b` fails AFTER `file_a` succeeds
      File.chmod!(dir_b, 0o555)

      try do
        assert {:error, {:write_failed, "lib/b/second.ex", _reason}} =
                 SymbolRefactor.rename_symbol(tmp_dir, "Rollback.Target", "Rollback.Updated")

        # `file_a` MUST be rolled back to `orig_a`!
        assert File.read!(file_a) == orig_a
        assert File.read!(file_b) == orig_b
      after
        File.chmod!(dir_b, 0o755)
      end
    end

    @tag :tmp_dir
    test "rejects malformed symbol specs and target names cleanly", %{tmp_dir: tmp_dir} do
      assert {:error, {:invalid_symbol_spec, ""}} =
               SymbolRefactor.find_references(tmp_dir, "")

      assert {:error, {:invalid_symbol_spec, _}} =
               SymbolRefactor.find_references(tmp_dir, "orphan_fun_without_module")

      assert {:error, {:invalid_symbol_spec, _}} =
               SymbolRefactor.find_references(tmp_dir, "MyApp.Worker.run/not_an_int")

      assert {:error, {:invalid_target_name, _}} =
               SymbolRefactor.rename_symbol(tmp_dir, "MyApp.OldMod", "lowercase_not_a_module")

      assert {:error, {:invalid_target_name, _}} =
               SymbolRefactor.rename_symbol(tmp_dir, "MyApp.Worker.run/1", "DifferentMod.run")
    end

    @tag :tmp_dir
    test "handles macros, ?/! predicates, 3-item multi-alias expansion, string interpolation, and format_references/2",
         %{tmp_dir: tmp_dir} do
      macros_file = Path.join(tmp_dir, "lib/macros.ex")
      user_file = Path.join(tmp_dir, "lib/user.ex")
      File.mkdir_p!(Path.join(tmp_dir, "lib"))

      File.write!(macros_file, """
      defmodule MyApp.OldMod do
        defmacro with_span(label, do: block) do
          quote do
            _ = unquote(label)
            unquote(block)
          end
        end

        def valid?(x), do: x != nil
      end
      """)

      File.write!(user_file, ~S"""
      defmodule MyApp.Consumer do
        require MyApp.OldMod
        alias MyApp.{OldMod, Alpha, Beta}

        def check(item) do
          msg = "MyApp.OldMod.valid?(item) -> #{MyApp.OldMod.valid?(item)}"

          OldMod.with_span("check") do
            {msg, Alpha, Beta, OldMod.valid?(item)}
          end
        end
      end
      """)

      # Check find_references + format_references/2
      assert {:ok, macro_refs} =
               SymbolRefactor.find_references(tmp_dir, "MyApp.OldMod.with_span/2")

      assert Enum.map(macro_refs, & &1.kind) == [:definition, :call]
      formatted = SymbolRefactor.format_references(macro_refs)
      assert formatted =~ "lib/macros.ex:2:"
      assert formatted =~ "[definition]"
      assert formatted =~ "lib/user.ex:8:"
      assert formatted =~ "[call]"
      assert SymbolRefactor.format_references([]) == "No symbol references found."

      # Rename predicate function `valid?/1` -> `ready?`
      assert {:ok, %{files_changed: 2, occurrences: 3}} =
               SymbolRefactor.rename_symbol(tmp_dir, "MyApp.OldMod.valid?/1", "ready?")

      updated_user = File.read!(user_file)
      # Literal half of string untouched, interpolated expression updated!
      assert updated_user =~
               ~S|msg = "MyApp.OldMod.valid?(item) -> #{MyApp.OldMod.ready?(item)}"|

      assert updated_user =~ "OldMod.ready?(item)"

      # Rename macro `with_span/2` -> `trace_span`
      assert {:ok, %{files_changed: 2, occurrences: 2}} =
               SymbolRefactor.rename_symbol(tmp_dir, "MyApp.OldMod.with_span/2", "trace_span")

      assert File.read!(macros_file) =~ "defmacro trace_span(label, do: block) do"
      assert File.read!(user_file) =~ ~s|OldMod.trace_span("check") do|

      # Rename module `MyApp.OldMod` -> `Core.Telemetry.SpanMod` (3-item cross-namespace multi-alias)
      assert {:ok, %{files_changed: 2}} =
               SymbolRefactor.rename_symbol(tmp_dir, "MyApp.OldMod", "Core.Telemetry.SpanMod")

      final_user = File.read!(user_file)
      assert final_user =~ "require Core.Telemetry.SpanMod"
      assert final_user =~ "alias MyApp.{Alpha, Beta}"
      assert final_user =~ "alias Core.Telemetry.SpanMod"

      assert final_user =~
               ~S|msg = "MyApp.OldMod.valid?(item) -> #{Core.Telemetry.SpanMod.ready?(item)}"|

      assert final_user =~ ~s|SpanMod.trace_span("check") do|
      assert final_user =~ "SpanMod.ready?(item)"
      assert {:ok, _} = Code.string_to_quoted(final_user)
    end
  end
end

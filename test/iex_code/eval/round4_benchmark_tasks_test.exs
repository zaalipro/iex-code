defmodule IexCode.Eval.Round4BenchmarkTasksTest do
  use ExUnit.Case, async: true

  alias IexCode.Eval.{Runner, Task}
  alias IexCode.Tools.{RepoMap, TestSelector}

  @ts_fixed_source """
  export interface SymbolEntry {
    name: string;
    kind: "function" | "class" | "interface" | "type" | "method";
    namespace?: string;
    params?: string[];
    returnType?: string;
  }

  export class SymbolTable {
    private entries: Map<string, SymbolEntry> = new Map();

    register(entry: SymbolEntry): void {
      const key = entry.namespace ? `${entry.namespace}.${entry.name}` : entry.name;
      this.entries.set(key, entry);
    }

    resolve(name: string, namespace?: string): SymbolEntry | undefined {
      const key = namespace ? `${namespace}.${name}` : name;
      return this.entries.get(key);
    }

    size(): number {
      return this.entries.size;
    }
  }

  export function formatSymbolSignature(entry: SymbolEntry): string {
    const qualified = entry.namespace ? `${entry.namespace}.${entry.name}` : entry.name;
    const params = (entry.params ?? []).join(", ");
    const ret = entry.returnType ? `: ${entry.returnType}` : "";
    return `${entry.kind} ${qualified}(${params})${ret}`;
  }
  """

  @feedback_fixed_source """
  defmodule FeedbackRepair do
    @moduledoc \"\"\"
    Bounded verifier feedback-repair loop state machine.
    \"\"\"

    @type finding :: %{file: String.t(), line: non_neg_integer(), reason: String.t()}

    @spec new(keyword()) :: map()
    def new(opts \\\\ []) do
      max_rounds = Keyword.get(opts, :max_rounds, 3)

      %{
        round: 0,
        max_rounds: max_rounds,
        status: :pending,
        open_findings: [],
        resolved_findings: [],
        history: []
      }
    end

    @spec record_verdict(map(), map()) :: {:ok, map()} | {:error, term()}
    def record_verdict(state, %{status: status} = verdict)
        when status in [:approved, :changes_requested] do
      raw_findings = Map.get(verdict, :findings, [])

      findings =
        raw_findings
        |> Enum.uniq()
        |> Enum.sort_by(fn f -> {f.file, f.line, f.reason} end)

      if status == :approved and findings != [] do
        {:error, :approved_with_findings}
      else
        next_round = state.round + 1
        newly_resolved = Enum.reject(state.open_findings, &(&1 in findings))

        resolved =
          (state.resolved_findings ++ newly_resolved)
          |> Enum.reject(&(&1 in findings))
          |> Enum.uniq()
          |> Enum.sort_by(fn f -> {f.file, f.line, f.reason} end)

        next_status =
          cond do
            status == :approved -> :approved
            next_round >= state.max_rounds -> :exhausted
            true -> :repairing
          end

        entry = %{round: next_round, status: status, findings: findings}

        {:ok,
         %{
           state
           | round: next_round,
             status: next_status,
             open_findings: findings,
             resolved_findings: resolved,
             history: state.history ++ [entry]
         }}
      end
    end

    def record_verdict(_state, _verdict), do: {:error, :invalid_verdict}

    @spec next_action(map()) ::
            {:halt, :approved | :max_rounds_exceeded} | {:repair, pos_integer(), [finding()]}
    def next_action(%{status: :approved}), do: {:halt, :approved}
    def next_action(%{status: :exhausted}), do: {:halt, :max_rounds_exceeded}

    def next_action(state) do
      {:repair, state.round + 1, state.open_findings}
    end
  end
  """

  describe "Round 4 benchmark tasks #11-#12" do
    test "tasks #11 and #12 load cleanly and fail in their baseline state" do
      assert {:ok, all_tasks} = Task.load_dir("eval/tasks")
      assert length(all_tasks) == 12

      r4_tasks =
        Task.filter(all_tasks,
          only: ["polyglot-ts-symbol-bugfix", "elixir-swarm-feedback-repair"]
        )

      assert Enum.map(r4_tasks, & &1.id) == [
               "elixir-swarm-feedback-repair",
               "polyglot-ts-symbol-bugfix"
             ]

      assert {:ok, baseline_results} =
               Runner.run("eval/tasks",
                 only: ["polyglot-ts-symbol-bugfix", "elixir-swarm-feedback-repair"],
                 samples: 1,
                 loop_fn: fn _prompt, _workdir, _task -> {:ok, %{turns: 0}} end
               )

      assert baseline_results.aggregate.samples == 2
      assert baseline_results.aggregate.passed == 0
    end

    test "tasks #11 and #12 pass 2/2 when reference fixes are applied" do
      assert {:ok, fixed_results} =
               Runner.run("eval/tasks",
                 only: ["polyglot-ts-symbol-bugfix", "elixir-swarm-feedback-repair"],
                 samples: 1,
                 loop_fn: fn _prompt, workdir, task ->
                   case task.id do
                     "polyglot-ts-symbol-bugfix" ->
                       File.write!(Path.join(workdir, "src/symbol_resolver.ts"), @ts_fixed_source)

                     "elixir-swarm-feedback-repair" ->
                       File.write!(
                         Path.join(workdir, "lib/feedback_repair.ex"),
                         @feedback_fixed_source
                       )
                   end

                   {:ok, %{turns: 1}}
                 end
               )

      assert fixed_results.aggregate.samples == 2
      assert fixed_results.aggregate.passed == 2
      assert fixed_results.aggregate.pass_rate == 1.0
    end
  end

  describe "Polyglot RepoMap and TestSelector test-pairing" do
    @tag :tmp_dir
    test "pairs TS/JS, Python, Go, and Rust source files with their convention tests in TestSelector and RepoMap",
         %{tmp_dir: tmp_dir} do
      # TypeScript: foo.ts -> foo.test.ts, foo.spec.ts, __tests__/foo.test.ts
      File.mkdir_p!(Path.join(tmp_dir, "web/__tests__"))
      File.write!(Path.join(tmp_dir, "web/auth.ts"), "export function login() { return true; }\n")
      File.write!(Path.join(tmp_dir, "web/auth.test.ts"), "import { login } from './auth';\n")
      File.write!(Path.join(tmp_dir, "web/auth.spec.ts"), "import { login } from './auth';\n")
      File.write!(Path.join(tmp_dir, "web/__tests__/auth.test.ts"), "test('auth', () => {});\n")

      File.write!(
        Path.join(tmp_dir, "web/checkout.test.ts"),
        "import { login } from './auth';\n"
      )

      # Python: foo.py -> test_foo.py, foo_test.py
      File.mkdir_p!(Path.join(tmp_dir, "pypkg"))
      File.write!(Path.join(tmp_dir, "pypkg/parser.py"), "def parse(x):\n    return x\n")
      File.write!(Path.join(tmp_dir, "pypkg/test_parser.py"), "def test_parse(): pass\n")
      File.write!(Path.join(tmp_dir, "pypkg/parser_test.py"), "def test_other(): pass\n")

      # Go: foo.go -> foo_test.go
      File.mkdir_p!(Path.join(tmp_dir, "pkg/store"))
      File.write!(Path.join(tmp_dir, "pkg/store/cache.go"), "package store\nfunc Get() {}\n")
      File.write!(Path.join(tmp_dir, "pkg/store/cache_test.go"), "package store\n")

      # Rust: foo.rs -> tests/foo.rs
      File.mkdir_p!(Path.join(tmp_dir, "src"))
      File.mkdir_p!(Path.join(tmp_dir, "tests"))
      File.write!(Path.join(tmp_dir, "src/router.rs"), "pub fn route() {}\n")
      File.write!(Path.join(tmp_dir, "tests/router.rs"), "fn test_route() {}\n")

      # TS mirror + reference ranking
      assert {:ok, ts_sel} =
               TestSelector.select(tmp_dir, changed_files: ["web/auth.ts"])

      assert "web/auth.test.ts" in ts_sel.paths
      assert "web/auth.spec.ts" in ts_sel.paths
      assert "web/__tests__/auth.test.ts" in ts_sel.paths
      assert ts_sel.reasons["web/auth.test.ts"] == :mirror
      assert ts_sel.reasons["web/auth.spec.ts"] == :mirror
      assert ts_sel.reasons["web/__tests__/auth.test.ts"] == :mirror
      assert ts_sel.reasons["web/checkout.test.ts"] == :reference

      # Python mirror
      assert {:ok, py_sel} = TestSelector.select(tmp_dir, changed_files: ["pypkg/parser.py"])
      assert py_sel.paths == ["pypkg/parser_test.py", "pypkg/test_parser.py"]
      assert py_sel.reasons["pypkg/test_parser.py"] == :mirror
      assert py_sel.reasons["pypkg/parser_test.py"] == :mirror

      # Go mirror
      assert {:ok, go_sel} =
               TestSelector.select(tmp_dir, changed_files: ["pkg/store/cache.go"])

      assert go_sel.paths == ["pkg/store/cache_test.go"]
      assert go_sel.reasons["pkg/store/cache_test.go"] == :mirror

      # Rust mirror
      assert {:ok, rs_sel} = TestSelector.select(tmp_dir, changed_files: ["src/router.rs"])
      assert rs_sel.paths == ["tests/router.rs"]
      assert rs_sel.reasons["tests/router.rs"] == :mirror

      # Direct test modification gets :direct priority over :mirror
      assert {:ok, direct_sel} =
               TestSelector.select(tmp_dir,
                 changed_files: ["web/auth.ts", "web/auth.test.ts"]
               )

      assert hd(direct_sel.paths) == "web/auth.test.ts"
      assert direct_sel.reasons["web/auth.test.ts"] == :direct
      assert direct_sel.reasons["web/auth.spec.ts"] == :mirror

      # RepoMap.paired_tests/2 and RepoMap.generate/2 surface paired tests
      assert {:ok, ts_pairs} = RepoMap.paired_tests(tmp_dir, "web/auth.ts")
      assert "web/auth.test.ts" in ts_pairs
      assert "web/auth.spec.ts" in ts_pairs
      assert "web/__tests__/auth.test.ts" in ts_pairs

      assert {:ok, go_pairs} = RepoMap.paired_tests(tmp_dir, "pkg/store/cache.go")
      assert go_pairs == ["pkg/store/cache_test.go"]

      assert {:ok, rs_pairs} = RepoMap.paired_tests(tmp_dir, "src/router.rs")
      assert rs_pairs == ["tests/router.rs"]

      assert {:ok, map_out} = RepoMap.generate(tmp_dir)
      assert map_out =~ "Tests: web/__tests__/auth.test.ts, web/auth.spec.ts, web/auth.test.ts"
      assert map_out =~ "Tests: pkg/store/cache_test.go"
      assert map_out =~ "Tests: tests/router.rs"
    end
  end
end

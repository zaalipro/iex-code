defmodule IexCode.Tools.AutoFixTest do
  use ExUnit.Case, async: false
  alias IexCode.Tools.AutoFix
  alias IexCode.Tools.TestRunner.{Result, Failure, CompilationError, StackFrame}

  describe "analyze_failures/2" do
    test "resolves lib/ stack trace frame over test file" do
      failure = %Failure{
        index: 1,
        test_name: "test adds two numbers",
        module: "CalcTest",
        file: "test/calc_test.exs",
        line: 10,
        message: "Assertion with == failed\nleft: 3\nright: 4",
        left: "3",
        right: "4",
        stacktrace: [
          %StackFrame{
            file: "lib/calc.ex",
            line: 5,
            app: "iex_code",
            context: "Calc.add/2",
            raw: "lib/calc.ex:5: Calc.add/2"
          },
          %StackFrame{
            file: "test/calc_test.exs",
            line: 10,
            app: "iex_code",
            context: "test adds two numbers",
            raw: "test/calc_test.exs:10"
          }
        ]
      }

      result = %Result{
        status: :failed,
        total: 1,
        passed: 0,
        failures_count: 1,
        failures: [failure],
        compilation_errors: []
      }

      assert {:ok, [analyzed]} = AutoFix.analyze_failures("/tmp", result)
      assert analyzed.file == "lib/calc.ex"
      assert analyzed.line == 5
      assert analyzed.source == :stacktrace
      assert analyzed.error_type == :assertion_mismatch
      assert analyzed.left == "3"
      assert analyzed.right == "4"
    end

    test "classifies compilation errors and extracts target file" do
      comp_err = %CompilationError{
        error_type: "CompileError",
        file: "lib/broken.ex",
        line: 8,
        column: 3,
        message: "variable \"unused_var\" is unused"
      }

      result = %Result{
        status: :compilation_error,
        total: 0,
        passed: 0,
        failures_count: 0,
        failures: [],
        compilation_errors: [comp_err]
      }

      assert {:ok, [analyzed]} = AutoFix.analyze_failures("/tmp", result)
      assert analyzed.file == "lib/broken.ex"
      assert analyzed.line == 8
      assert analyzed.error_type == :unused_variable
    end
  end

  describe "generate_patch_proposals/3 and apply_auto_fix/3" do
    @tag :tmp_dir
    test "fixes unused variable warning via heuristic", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "lib/worker.ex")
      File.mkdir_p!(Path.dirname(file_path))

      File.write!(
        file_path,
        "defmodule Worker do\n  def process(item, count) do\n    item * 2\n  end\nend"
      )

      comp_err = %CompilationError{
        error_type: "CompileError",
        file: "lib/worker.ex",
        line: 2,
        message:
          "variable \"count\" is unused (if the variable is not meant to be used, prefix it with an underscore: _count)"
      }

      assert {:ok, [patch]} = AutoFix.generate_patch_proposals(tmp_dir, comp_err)
      assert patch.path == "lib/worker.ex"
      assert String.contains?(patch.target, "count")
      assert String.contains?(patch.replacement, "_count")

      # Apply fix
      assert {:ok, summary} = AutoFix.apply_auto_fix(tmp_dir, comp_err)
      assert summary.applied == 1

      content = File.read!(file_path)
      assert String.contains?(content, "def process(item, _count)")
    end

    @tag :tmp_dir
    test "fixes function typo via heuristic", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "lib/service.ex")
      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, "defmodule Service do\n  def proccess_data(x), do: x * 2\nend")

      failure = %Failure{
        index: 1,
        test_name: "test process_data",
        module: "ServiceTest",
        file: "test/service_test.exs",
        line: 5,
        message: "function Service.proccess_data/1 is undefined or private",
        stacktrace: [
          %StackFrame{file: "lib/service.ex", line: 2, app: "app", context: nil, raw: ""}
        ]
      }

      assert {:ok, [patch]} = AutoFix.generate_patch_proposals(tmp_dir, failure)
      assert patch.path == "lib/service.ex"
      assert patch.target == "def proccess_data(x)"
      assert patch.replacement == "def process_data(x)"

      assert {:ok, summary} = AutoFix.apply_auto_fix(tmp_dir, failure)
      assert summary.applied == 1

      content = File.read!(file_path)
      assert String.contains?(content, "def process_data(x)")
    end

    @tag :tmp_dir
    test "fixes syntax error with missing colon", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "lib/syntax_err.ex")
      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, "defmodule SyntaxErr do\n  def get_val, do :ok\nend")

      comp_err = %CompilationError{
        error_type: "SyntaxError",
        file: "lib/syntax_err.ex",
        line: 2,
        message: "syntax error before: :ok"
      }

      assert {:ok, [patch]} = AutoFix.generate_patch_proposals(tmp_dir, comp_err)
      assert patch.path == "lib/syntax_err.ex"
      assert String.contains?(patch.target, "do :ok")
      assert String.contains?(patch.replacement, "do: :ok")

      assert {:ok, summary} = AutoFix.apply_auto_fix(tmp_dir, comp_err)
      assert summary.applied == 1

      content = File.read!(file_path)
      assert String.contains?(content, "def get_val, do: :ok")
    end
  end

  describe "format_diagnostics/1" do
    test "formats diagnostic markdown report" do
      failure = %Failure{
        index: 1,
        test_name: "test math",
        module: "MathTest",
        file: "test/math_test.exs",
        line: 12,
        message: "Assertion failed",
        left: "4",
        right: "5"
      }

      result = %Result{
        status: :failed,
        total: 1,
        passed: 0,
        failures_count: 1,
        failures: [failure],
        compilation_errors: []
      }

      formatted = AutoFix.format_diagnostics(result)
      assert is_binary(formatted)
      assert String.contains?(formatted, "Failure 1: test math")
      assert String.contains?(formatted, "Left: 4")
      assert String.contains?(formatted, "Right: 5")
    end
  end
end

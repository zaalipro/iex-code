defmodule IexCode.Tools.TestRunner do
  @moduledoc """
  Automated test execution engine for Mix and ExUnit test suites.
  Executes tests inside the project workspace with timeout controls,
  progress reporting, file/line filters, and structured failure parsing.
  """

  alias IexCode.Tools.TestRunner.{Parser, Result}

  @type run_opts :: [
          project_root: Path.t(),
          paths: [Path.t()] | Path.t(),
          line: pos_integer() | nil,
          failed: boolean(),
          stale: boolean(),
          seed: integer() | nil,
          max_failures: integer() | nil,
          include: String.t() | atom() | [String.t() | atom()],
          exclude: String.t() | atom() | [String.t() | atom()],
          only: String.t() | atom() | [String.t() | atom()],
          trace: boolean(),
          timeout_ms: integer(),
          env: %{String.t() => String.t()},
          on_progress: (non_neg_integer(), String.t() -> any())
        ]

  @doc """
  Runs `mix test` with the provided options.
  """
  @spec run(run_opts()) :: {:ok, Result.t()} | {:error, term()}
  def run(opts) when is_list(opts) do
    project_root = Keyword.get(opts, :project_root, File.cwd!())
    run(project_root, opts)
  end

  @doc """
  Runs `mix test` inside `project_root` with the provided options.
  """
  @spec run(Path.t(), run_opts()) :: {:ok, Result.t()} | {:error, term()}
  def run(project_root, opts) when is_binary(project_root) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 60_000)
    on_progress = Keyword.get(opts, :on_progress, fn _pct, _msg -> :ok end)
    env = Keyword.get(opts, :env, %{"MIX_ENV" => "test"})

    args = build_mix_test_args(opts)

    on_progress.(10, "Starting mix test in #{project_root}...")

    task =
      Task.async(fn ->
        System.cmd("mix", args, cd: project_root, env: env, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {raw_output, exit_code}} ->
        on_progress.(80, "Parsing test results...")
        result = Parser.parse(raw_output, exit_code)

        on_progress.(
          100,
          "Completed test run (#{result.total} tests, #{result.failures_count} failures)"
        )

        {:ok, result}

      nil ->
        on_progress.(100, "Test execution timed out after #{timeout_ms}ms")
        {:error, :timeout}
    end
  end

  @doc """
  Shortcut to run a specific test file and optional line number.
  """
  @spec run_file(Path.t(), pos_integer() | nil, run_opts()) ::
          {:ok, Result.t()} | {:error, term()}
  def run_file(file_path, line \\ nil, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:paths, [file_path])
      |> Keyword.put(:line, line)

    run(opts)
  end

  # --- Internal Helpers ---

  defp build_mix_test_args(opts) do
    base_args = ["test", "--color"]

    paths_args =
      case Keyword.get(opts, :paths) do
        nil ->
          []

        path when is_binary(path) ->
          line = Keyword.get(opts, :line)

          if is_integer(line) and not String.contains?(path, ":") do
            ["#{path}:#{line}"]
          else
            [path]
          end

        paths when is_list(paths) ->
          line = Keyword.get(opts, :line)

          if length(paths) == 1 and is_integer(line) do
            single = hd(paths)

            if not String.contains?(single, ":") do
              ["#{single}:#{line}"]
            else
              paths
            end
          else
            paths
          end
      end

    flag_args =
      []
      |> add_bool_flag(opts, :failed, "--failed")
      |> add_bool_flag(opts, :stale, "--stale")
      |> add_bool_flag(opts, :trace, "--trace")
      |> add_val_flag(opts, :seed, "--seed")
      |> add_val_flag(opts, :max_failures, "--max-failures")
      |> add_tag_flags(opts, :include, "--include")
      |> add_tag_flags(opts, :exclude, "--exclude")
      |> add_tag_flags(opts, :only, "--only")

    base_args ++ flag_args ++ paths_args
  end

  defp add_bool_flag(acc, opts, key, flag) do
    if Keyword.get(opts, key) == true, do: acc ++ [flag], else: acc
  end

  defp add_val_flag(acc, opts, key, flag) do
    case Keyword.get(opts, key) do
      val when val != nil and val != "" -> acc ++ [flag, to_string(val)]
      _ -> acc
    end
  end

  defp add_tag_flags(acc, opts, key, flag) do
    case Keyword.get(opts, key) do
      tags when is_list(tags) ->
        Enum.reduce(tags, acc, fn t, a -> a ++ [flag, to_string(t)] end)

      tag when tag != nil and tag != "" ->
        acc ++ [flag, to_string(tag)]

      _ ->
        acc
    end
  end
end

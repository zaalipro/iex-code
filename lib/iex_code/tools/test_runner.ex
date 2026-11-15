defmodule IexCode.Tools.TestRunner do
  @moduledoc """
  Automated test execution engine for Mix and ExUnit test suites.
  Executes tests inside the project workspace with isolated POSIX process-group
  timeout reaping, incremental changed-file test selection, ephemeral
  `MIX_TEST_PARTITION` SQLite cleanup, progress reporting, and structured
  failure parsing.
  """

  alias IexCode.Tools.{ProcessGroupRunner, TestSelector}
  alias IexCode.Tools.TestRunner.{Parser, Result}
  alias IexCode.WorkspacePath

  @excluded_cleanup_dirs MapSet.new(~w(.git _build deps node_modules))

  @type run_opts :: [
          project_root: Path.t(),
          paths: [Path.t()] | Path.t(),
          line: pos_integer() | nil,
          changed: boolean(),
          changed_files: [Path.t()] | Path.t() | nil,
          fallback: :none | :stale | :all,
          max_targets: pos_integer(),
          partition: :auto | String.t() | nil,
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
    base_env = Keyword.get(opts, :env, %{"MIX_ENV" => "test"})

    with {:ok, canonical_root} <- WorkspacePath.resolve(project_root, "."),
         {:ok, partition} <- resolve_partition(Keyword.get(opts, :partition)),
         {:ok, plan} <- resolve_execution_plan(canonical_root, opts) do
      case plan do
        {:skip, %Result{} = empty_result} ->
          on_progress.(10, "Selecting changed tests in #{project_root}...")
          on_progress.(100, "No matching tests selected (0 tests, 0 failures)")
          {:ok, empty_result}

        {:run, resolved_opts} ->
          args = build_mix_test_args(resolved_opts)
          env = inject_partition_env(base_env, partition)

          on_progress.(10, "Starting mix test in #{project_root}...")

          try do
            case run_mix_test(args, canonical_root, env, timeout_ms) do
              {:ok, {raw_output, exit_code}} ->
                on_progress.(80, "Parsing test results...")
                result = Parser.parse(raw_output, exit_code)

                on_progress.(
                  100,
                  "Completed test run (#{result.total} tests, #{result.failures_count} failures)"
                )

                {:ok, result}

              {:error, :timeout} ->
                on_progress.(100, "Test execution timed out after #{timeout_ms}ms")
                {:error, :timeout}

              {:error, reason} ->
                on_progress.(100, "Test execution failed: #{inspect(reason)}")
                {:error, reason}
            end
          after
            cleanup_partition_dbs(canonical_root, partition)
          end
      end
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

  defp resolve_partition(nil), do: {:ok, nil}
  defp resolve_partition(false), do: {:ok, nil}
  defp resolve_partition(""), do: {:ok, nil}

  defp resolve_partition(:auto) do
    id = System.unique_integer([:positive])
    proc_tag = :erlang.phash2(self())
    {:ok, "_tr_#{id}_#{proc_tag}"}
  end

  defp resolve_partition(partition) when is_binary(partition) do
    if Regex.match?(~r/^[A-Za-z0-9_-]+$/, partition) do
      {:ok, partition}
    else
      {:error, {:invalid_partition, partition}}
    end
  end

  defp resolve_partition(other), do: {:error, {:invalid_partition, other}}

  defp inject_partition_env(env, nil), do: env

  defp inject_partition_env(env, partition) when is_map(env) and is_binary(partition) do
    Map.put(env, "MIX_TEST_PARTITION", partition)
  end

  defp resolve_execution_plan(canonical_root, opts) do
    explicit_paths = Keyword.get(opts, :paths)
    changed? = Keyword.get(opts, :changed) == true
    changed_files = Keyword.get(opts, :changed_files)

    cond do
      non_empty_paths?(explicit_paths) ->
        {:ok, {:run, opts}}

      changed? or changed_files != nil ->
        resolve_changed_plan(canonical_root, opts, changed_files)

      true ->
        {:ok, {:run, opts}}
    end
  end

  defp non_empty_paths?(nil), do: false
  defp non_empty_paths?(""), do: false
  defp non_empty_paths?([]), do: false
  defp non_empty_paths?(path) when is_binary(path), do: true
  defp non_empty_paths?(paths) when is_list(paths), do: true
  defp non_empty_paths?(_), do: false

  defp resolve_changed_plan(canonical_root, opts, changed_files) do
    selector_opts =
      []
      |> maybe_put_opt(:changed_files, changed_files)
      |> maybe_put_opt(:max_targets, Keyword.get(opts, :max_targets))

    fallback = Keyword.get(opts, :fallback, :none)

    with {:ok, %{paths: selected_paths}} <- TestSelector.select(canonical_root, selector_opts) do
      case selected_paths do
        [] ->
          apply_empty_selection_fallback(opts, fallback)

        paths ->
          {:ok, {:run, Keyword.put(opts, :paths, paths)}}
      end
    end
  end

  defp apply_empty_selection_fallback(_opts, :none) do
    result = %Result{
      status: :passed,
      total: 0,
      passed: 0,
      failures_count: 0,
      excluded: 0,
      skipped: 0,
      invalid: 0,
      duration_s: 0.0,
      seed: nil,
      failures: [],
      compilation_errors: [],
      raw_output: "No matching tests selected for changed files; skipping test run.",
      exit_code: 0
    }

    {:ok, {:skip, result}}
  end

  defp apply_empty_selection_fallback(opts, :stale) do
    resolved_opts =
      opts
      |> Keyword.delete(:paths)
      |> Keyword.put(:stale, true)

    {:ok, {:run, resolved_opts}}
  end

  defp apply_empty_selection_fallback(opts, :all) do
    {:ok, {:run, Keyword.delete(opts, :paths)}}
  end

  defp apply_empty_selection_fallback(_opts, other) do
    {:error, {:invalid_fallback, other}}
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, val), do: Keyword.put(opts, key, val)

  defp run_mix_test(args, canonical_root, env, timeout_ms) do
    case System.find_executable("mix") do
      nil ->
        {:error, :mix_not_found}

      mix_path ->
        command = Enum.map_join([mix_path | args], " ", &shell_escape/1)

        case ProcessGroupRunner.run(command,
               cd: canonical_root,
               env: env,
               timeout_ms: timeout_ms
             ) do
          {:ok, %{exit_code: exit_code, output: raw_output}} ->
            {:ok, {raw_output, exit_code}}

          {:timeout, _meta} ->
            {:error, :timeout}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp shell_escape(arg) do
    str = to_string(arg)
    "'" <> String.replace(str, "'", "'\"'\"'") <> "'"
  end

  defp cleanup_partition_dbs(_canonical_root, nil), do: :ok

  defp cleanup_partition_dbs(canonical_root, partition) when is_binary(partition) do
    patterns = [
      Path.join(canonical_root, "*_test#{partition}.db*"),
      Path.join(canonical_root, "*/*_test#{partition}.db*"),
      Path.join(canonical_root, "apps/*/*_test#{partition}.db*")
    ]

    patterns
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.each(fn candidate ->
      with {:ok, resolved} <- WorkspacePath.resolve(canonical_root, candidate),
           rel <- Path.relative_to(resolved, canonical_root),
           false <- excluded_cleanup_path?(rel),
           true <- File.regular?(resolved) do
        File.rm(resolved)
      else
        _ -> :ok
      end
    end)

    :ok
  rescue
    _ -> :ok
  end

  defp excluded_cleanup_path?(rel) do
    rel
    |> Path.split()
    |> Enum.any?(&MapSet.member?(@excluded_cleanup_dirs, &1))
  end

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

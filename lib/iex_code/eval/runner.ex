defmodule IexCode.Eval.Runner do
  @moduledoc """
  Runs eval tasks: fresh workdir per sample, agent loop, grade command.

  Options:
    * `:samples` — samples per task (default 1)
    * `:ks` — pass@k curve points (default [1])
    * `:only` — optional list of task ids to run
    * `:category` — optional task category filter
    * `:tag` — optional task tag filter
    * `:max_turns` — optional max turns override per task
    * `:keep_workdir` — preserve temporary workdirs on disk after grading (default false)
    * `:loop_fn` — `(prompt, workdir, task -> {:ok, map()} | {:error, term()})`;
      defaults to a real `AgentLoop` run with ephemeral rows
    * `:llm`, `:tool_executor` — adapters for the default loop
    * `:on_sample` — `(task, sample_result -> any())` progress callback
  """

  alias IexCode.Eval.Scoring
  alias IexCode.Eval.Task, as: EvalTask
  alias IexCode.Engine.AgentLoop
  alias IexCode.{Projects, Runs, Sessions}

  @type sample :: %{
          required(:sample) => pos_integer(),
          required(:passed) => boolean(),
          required(:loop) => term(),
          required(:grade) => term(),
          required(:workdir) => String.t(),
          required(:duration_ms) => non_neg_integer(),
          required(:turns) => non_neg_integer() | nil,
          required(:tool_calls) => non_neg_integer() | nil,
          required(:input_tokens) => non_neg_integer() | nil,
          required(:output_tokens) => non_neg_integer() | nil,
          required(:cost_cents) => non_neg_integer() | nil,
          optional(:error) => term()
        }

  @doc "Runs matching tasks in `dir` and returns per-task, per-category, and aggregate results."
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(dir, opts \\ []) when is_binary(dir) and is_list(opts) do
    samples = Keyword.get(opts, :samples, 1)
    ks = Keyword.get(opts, :ks, [1])
    only = Keyword.get(opts, :only)
    category = Keyword.get(opts, :category)
    tag = Keyword.get(opts, :tag)
    max_turns = Keyword.get(opts, :max_turns)

    with {:ok, tasks} <- EvalTask.load_dir(dir),
         true <- (is_integer(samples) and samples > 0) or {:error, :eval_bad_samples},
         true <- valid_ks?(ks) or {:error, :eval_bad_ks},
         true <- valid_only?(only) or {:error, :eval_bad_only},
         true <- valid_optional_string?(category) or {:error, :eval_bad_category},
         true <- valid_optional_string?(tag) or {:error, :eval_bad_tag},
         true <- valid_optional_pos_int?(max_turns) or {:error, :eval_bad_max_turns} do
      filtered_tasks =
        tasks
        |> EvalTask.filter(only: only, category: category, tag: tag)
        |> maybe_override_max_turns(max_turns)

      results = Enum.map(filtered_tasks, &run_task(&1, dir, samples, ks, opts))

      {:ok,
       %{
         dir: dir,
         samples: samples,
         ks: ks,
         tasks: results,
         aggregate: aggregate(results, ks),
         by_category: Scoring.summarize_by_category(results, ks)
       }}
    else
      false -> {:error, :eval_bad_options}
      {:error, _reason} = error -> error
    end
  end

  @doc "Formats a result map as a human-readable report."
  @spec format_report(map()) :: String.t()
  def format_report(%{tasks: tasks, aggregate: aggregate} = results) do
    header = "eval: #{length(tasks)} task(s) x #{results.samples} sample(s)"

    lines =
      Enum.map(tasks, fn task ->
        curve = format_curve(task.summary.pass_at_k)

        "  #{task.id}: #{task.summary.passed}/#{task.summary.samples} passed " <>
          "(rate=#{format_float(task.summary.pass_rate)} #{curve})"
      end)

    agg_curve = format_curve(aggregate.pass_at_k)

    footer =
      "aggregate: #{aggregate.passed}/#{aggregate.samples} passed " <>
        "(rate=#{format_float(aggregate.pass_rate)} #{agg_curve})"

    category_lines = format_category_lines(results)
    telemetry_line = format_telemetry_line(results)

    ([header | lines] ++ [footer] ++ category_lines ++ telemetry_line)
    |> Enum.join("\n")
  end

  @doc "Serializes a result map as a pretty-printed JSON report string."
  @spec to_json_report(map()) :: String.t()
  def to_json_report(%{tasks: tasks, aggregate: aggregate} = results) do
    ks = Map.get(results, :ks) || Map.keys(aggregate.pass_at_k) |> Enum.sort()
    by_category = Map.get(results, :by_category) || Scoring.summarize_by_category(tasks, ks)
    telemetry = summarize_telemetry(tasks)

    payload = %{
      "dir" => Map.get(results, :dir),
      "samples" => Map.get(results, :samples),
      "ks" => ks,
      "aggregate" =>
        serialize_summary(aggregate)
        |> Map.put("telemetry", telemetry),
      "by_category" =>
        Map.new(by_category, fn {category, summary} ->
          {category, serialize_summary(summary)}
        end),
      "tasks" => Enum.map(tasks, &serialize_task/1)
    }

    Jason.encode!(payload, pretty: true)
  end

  defp run_task(%EvalTask{} = task, dir, samples, ks, opts) do
    loop_fn = Keyword.get(opts, :loop_fn, &default_loop_fn(&1, &2, &3, opts))
    on_sample = Keyword.get(opts, :on_sample, fn _task, _sample -> :ok end)
    keep_workdir = Keyword.get(opts, :keep_workdir, false)

    results =
      for sample <- 1..samples do
        result = run_sample(task, dir, sample, loop_fn, keep_workdir)
        on_sample.(task, result)
        result
      end

    outcomes = Enum.map(results, & &1.passed)

    %{
      id: task.id,
      category: task.category,
      difficulty: task.difficulty,
      tags: task.tags,
      samples: results,
      summary: Scoring.summarize(outcomes, ks)
    }
  end

  defp run_sample(%EvalTask{} = task, dir, sample, loop_fn, keep_workdir) do
    fixture = Path.expand(task.repo, dir)
    workdir = Path.join(System.tmp_dir!(), "iex-eval-#{task.id}-#{sample}-#{uniq()}")
    started_at = System.monotonic_time(:millisecond)

    try do
      case prepare_workdir(fixture, workdir) do
        :ok ->
          run_prepared_sample(task, sample, workdir, loop_fn, started_at)

        {:error, reason} ->
          build_sample_result(sample, false, nil, nil, workdir, started_at, %{}, error: reason)
      end
    after
      unless keep_workdir do
        File.rm_rf(workdir)
      end
    end
  end

  defp run_prepared_sample(task, sample, workdir, loop_fn, started_at) do
    case loop_fn.(task.prompt, workdir, task) do
      {:ok, outcome} ->
        metrics = extract_metrics(outcome)

        case grade(task, workdir) do
          {:ok, grade} ->
            build_sample_result(
              sample,
              grade.passed,
              outcome,
              grade,
              workdir,
              started_at,
              metrics
            )

          {:error, reason} ->
            build_sample_result(sample, false, outcome, reason, workdir, started_at, metrics)
        end

      {:error, reason} ->
        build_sample_result(sample, false, {:error, reason}, nil, workdir, started_at, %{})

      other ->
        build_sample_result(sample, false, other, nil, workdir, started_at, %{})
    end
  end

  defp build_sample_result(sample, passed, loop, grade, workdir, started_at, metrics, extra \\ []) do
    duration_ms = max(0, System.monotonic_time(:millisecond) - started_at)

    base = %{
      sample: sample,
      passed: passed,
      loop: loop,
      grade: grade,
      workdir: workdir,
      duration_ms: duration_ms,
      turns: Map.get(metrics, :turns),
      tool_calls: Map.get(metrics, :tool_calls),
      input_tokens: Map.get(metrics, :input_tokens),
      output_tokens: Map.get(metrics, :output_tokens),
      cost_cents: Map.get(metrics, :cost_cents)
    }

    Enum.into(extra, base)
  end

  defp extract_metrics(outcome) when is_map(outcome) do
    usage = Map.get(outcome, :usage) || Map.get(outcome, "usage") || %{}

    %{
      turns: first_non_neg_int([Map.get(outcome, :turns), Map.get(outcome, "turns")]),
      tool_calls:
        first_non_neg_int([Map.get(outcome, :tool_calls), Map.get(outcome, "tool_calls")]),
      input_tokens:
        first_non_neg_int([
          Map.get(outcome, :input_tokens),
          Map.get(outcome, "input_tokens"),
          map_value(usage, :input_tokens),
          map_value(usage, "input_tokens"),
          map_value(usage, :prompt_tokens),
          map_value(usage, "prompt_tokens")
        ]),
      output_tokens:
        first_non_neg_int([
          Map.get(outcome, :output_tokens),
          Map.get(outcome, "output_tokens"),
          map_value(usage, :output_tokens),
          map_value(usage, "output_tokens"),
          map_value(usage, :completion_tokens),
          map_value(usage, "completion_tokens")
        ]),
      cost_cents:
        first_non_neg_int([
          Map.get(outcome, :cost_cents),
          Map.get(outcome, "cost_cents"),
          map_value(usage, :cost_cents),
          map_value(usage, "cost_cents")
        ])
    }
  end

  defp extract_metrics(_other), do: %{}

  defp map_value(map, key) when is_map(map), do: Map.get(map, key)
  defp map_value(_other, _key), do: nil

  defp first_non_neg_int(values) do
    Enum.find(values, &(is_integer(&1) and &1 >= 0))
  end

  defp prepare_workdir(fixture, workdir) do
    if File.dir?(fixture) do
      File.rm_rf!(workdir)

      case File.cp_r(fixture, workdir) do
        {:ok, _files} -> :ok
        {:error, reason, _file} -> {:error, {:eval_workdir_copy, reason}}
      end
    else
      {:error, {:eval_fixture_missing, fixture}}
    end
  end

  defp grade(%EvalTask{} = task, workdir) do
    [cmd | args] = task.test_cmd

    case resolve_executable(cmd, workdir) do
      {:ok, executable} ->
        run_grade_port(executable, args, workdir, task.timeout_ms)

      {:error, _reason} = error ->
        error
    end
  end

  defp resolve_executable(cmd, workdir) do
    if String.contains?(cmd, "/") do
      expanded = Path.expand(cmd, workdir)

      if File.regular?(expanded),
        do: {:ok, expanded},
        else: {:error, {:eval_grade_crashed, :enoent}}
    else
      case System.find_executable(cmd) do
        nil -> {:error, {:eval_grade_crashed, :enoent}}
        path -> {:ok, path}
      end
    end
  end

  defp run_grade_port(executable, args, workdir, timeout_ms) do
    port =
      Port.open(
        {:spawn_executable, executable},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          cd: workdir,
          args: args
        ]
      )

    deadline = System.monotonic_time(:millisecond) + timeout_ms

    try do
      collect_grade_output(port, deadline, [])
    after
      close_port_safely(port)
      flush_port_messages(port)
    end
  rescue
    error -> {:error, {:eval_grade_crashed, error}}
  catch
    :exit, reason -> {:error, {:eval_grade_crashed, reason}}
  end

  defp collect_grade_output(port, deadline, chunks) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, data}} ->
        collect_grade_output(port, deadline, [data | chunks])

      {^port, {:exit_status, exit_code}} ->
        output = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, %{passed: exit_code == 0, exit_code: exit_code, output: trim(output)}}
    after
      remaining ->
        kill_port_process_group(port)
        {:error, :eval_grade_timeout}
    end
  end

  defp kill_port_process_group(port) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
        _ -> nil
      end

    if os_pid do
      beam_pgid = process_pgid(System.pid())
      target_pgid = process_pgid(os_pid)

      if is_integer(target_pgid) and target_pgid > 0 and target_pgid != beam_pgid do
        _ = System.cmd("kill", ["-9", "-#{target_pgid}"], stderr_to_stdout: true)
      end

      if os_pid != beam_pgid do
        _ = System.cmd("kill", ["-9", "-#{os_pid}"], stderr_to_stdout: true)
      end

      _ = System.cmd("pkill", ["-9", "-P", "#{os_pid}"], stderr_to_stdout: true)
      _ = System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp process_pgid(pid) do
    case System.cmd("ps", ["-o", "pgid=", "-p", to_string(pid)], stderr_to_stdout: true) do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {pgid, ""} when pgid > 0 -> pgid
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp close_port_safely(port) do
    if Port.info(port) != nil do
      Port.close(port)
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp flush_port_messages(port) do
    receive do
      {^port, _msg} -> flush_port_messages(port)
    after
      0 -> :ok
    end
  end

  defp default_loop_fn(prompt, workdir, task, opts) do
    llm = Keyword.get(opts, :llm, IexCode.LLM)
    tool_executor = Keyword.get(opts, :tool_executor, IexCode.Tools)

    with {:ok, project} <-
           Projects.create_project(%{name: "eval-#{task.id}-#{uniq()}", root_path: workdir}),
         {:ok, session} <-
           Sessions.create_session(%{
             project_id: project.id,
             title: "eval #{task.id}",
             model_provider: "openai",
             model_name: "eval-model",
             temperature: 0.0
           }),
         {:ok, _queued} <-
           Runs.create_run(%{
             project_id: project.id,
             session_id: session.id,
             objective: prompt,
             kind: "coding_agent",
             mode: "single",
             metadata: %{
               "source" => "eval",
               "execution_policy" => %{"agent_max_turns" => task.max_turns}
             }
           }),
         {:ok, run} <- Runs.claim_next_run("eval:#{uniq()}", lease_ms: 300_000) do
      IexCode.Engine.SessionServer.update_session_overrides(session.id, %{
        "tool_approval_mode" => "full_auto",
        "file_mutations" => "auto",
        "shell_execution" => "auto",
        "git_push" => "auto",
        "autonomy" => "auto"
      })

      try do
        AgentLoop.execute(run, workdir, fn _percent, _message -> :ok end,
          llm: llm,
          tool_executor: tool_executor,
          run_lease_owner: run.lease_owner,
          run_attempt: run.attempt,
          run_lease_generation: run.lease_generation,
          run_terminal_lease_ms: 300_000
        )
      after
        Process.delete({:session_overrides, session.id})
      end
    end
  end

  defp aggregate(task_results, ks) do
    outcomes = Enum.flat_map(task_results, fn task -> Enum.map(task.samples, & &1.passed) end)
    Scoring.summarize(outcomes, ks)
  end

  defp maybe_override_max_turns(tasks, nil), do: tasks

  defp maybe_override_max_turns(tasks, max_turns) when is_integer(max_turns) and max_turns > 0 do
    Enum.map(tasks, &%{&1 | max_turns: max_turns})
  end

  defp valid_ks?(ks), do: is_list(ks) and ks != [] and Enum.all?(ks, &(is_integer(&1) and &1 > 0))
  defp valid_only?(nil), do: true
  defp valid_only?(only), do: is_list(only) and Enum.all?(only, &is_binary/1)

  defp valid_optional_string?(nil), do: true
  defp valid_optional_string?(val), do: is_binary(val) and String.trim(val) != ""

  defp valid_optional_pos_int?(nil), do: true
  defp valid_optional_pos_int?(val), do: is_integer(val) and val > 0

  defp format_curve(pass_at_k) do
    pass_at_k
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(" ", fn {k, v} -> "pass@#{k}=#{format_float(v)}" end)
  end

  defp format_category_lines(results) do
    by_category =
      Map.get(results, :by_category) ||
        Scoring.summarize_by_category(results.tasks, Map.get(results, :ks, [1]))

    if map_size(by_category) == 0 do
      []
    else
      entries =
        by_category
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {category, summary} ->
          curve = format_curve(summary.pass_at_k)

          "  #{category}: #{summary.passed}/#{summary.samples} passed " <>
            "(rate=#{format_float(summary.pass_rate)} #{curve})"
        end)

      ["by_category:" | entries]
    end
  end

  defp format_telemetry_line(results) do
    telemetry = summarize_telemetry(results.tasks)

    if telemetry["samples"] == 0 do
      []
    else
      parts =
        [
          "duration_ms=#{telemetry["total_duration_ms"]}",
          optional_metric("turns", telemetry["total_turns"]),
          optional_metric("tool_calls", telemetry["total_tool_calls"]),
          optional_metric("input_tokens", telemetry["total_input_tokens"]),
          optional_metric("output_tokens", telemetry["total_output_tokens"]),
          optional_metric("cost_cents", telemetry["total_cost_cents"])
        ]
        |> Enum.reject(&is_nil/1)

      ["telemetry: " <> Enum.join(parts, " ")]
    end
  end

  defp optional_metric(_label, nil), do: nil
  defp optional_metric(label, value), do: "#{label}=#{value}"

  defp summarize_telemetry(tasks) do
    samples = Enum.flat_map(tasks, &Map.get(&1, :samples, []))

    %{
      "samples" => length(samples),
      "total_duration_ms" => sum_present(samples, :duration_ms) || 0,
      "total_turns" => sum_present(samples, :turns),
      "total_tool_calls" => sum_present(samples, :tool_calls),
      "total_input_tokens" => sum_present(samples, :input_tokens),
      "total_output_tokens" => sum_present(samples, :output_tokens),
      "total_cost_cents" => sum_present(samples, :cost_cents)
    }
  end

  defp sum_present(samples, key) do
    values = samples |> Enum.map(&Map.get(&1, key)) |> Enum.filter(&is_integer/1)
    if values == [], do: nil, else: Enum.sum(values)
  end

  defp serialize_summary(summary) do
    %{
      "samples" => summary.samples,
      "passed" => summary.passed,
      "pass_rate" => summary.pass_rate,
      "pass_at_k" =>
        summary.pass_at_k
        |> Enum.sort_by(&elem(&1, 0))
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
    }
  end

  defp serialize_task(task) do
    %{
      "id" => task.id,
      "category" => Map.get(task, :category, "general"),
      "difficulty" => Map.get(task, :difficulty, "medium"),
      "tags" => Map.get(task, :tags, []),
      "summary" => serialize_summary(task.summary),
      "samples" => Enum.map(task.samples, &serialize_sample/1)
    }
  end

  defp serialize_sample(sample) do
    %{
      "sample" => sample.sample,
      "passed" => sample.passed,
      "workdir" => sample.workdir,
      "duration_ms" => Map.get(sample, :duration_ms),
      "turns" => Map.get(sample, :turns),
      "tool_calls" => Map.get(sample, :tool_calls),
      "input_tokens" => Map.get(sample, :input_tokens),
      "output_tokens" => Map.get(sample, :output_tokens),
      "cost_cents" => Map.get(sample, :cost_cents),
      "grade" => serialize_grade(Map.get(sample, :grade)),
      "error" => json_safe(Map.get(sample, :error))
    }
  end

  defp serialize_grade(nil), do: nil

  defp serialize_grade(%{passed: passed, exit_code: exit_code, output: output}) do
    %{"passed" => passed, "exit_code" => exit_code, "output" => output}
  end

  defp serialize_grade(other), do: %{"error" => inspect(other)}

  defp json_safe(nil), do: nil
  defp json_safe(val) when is_binary(val) or is_number(val) or is_boolean(val), do: val
  defp json_safe(val) when is_atom(val), do: Atom.to_string(val)
  defp json_safe(val), do: inspect(val)

  defp trim(output), do: String.slice(output || "", 0, 4_000)
  defp uniq, do: System.unique_integer([:positive])

  defp format_float(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 3)

  defp format_float(value), do: to_string(value)
end

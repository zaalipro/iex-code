defmodule IexCode.Eval.Runner do
  @moduledoc """
  Runs eval tasks: fresh workdir per sample, agent loop, grade command.

  Options:
    * `:samples` — samples per task (default 1)
    * `:ks` — pass@k curve points (default [1])
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
          sample: pos_integer(),
          passed: boolean(),
          loop: term(),
          grade: term(),
          workdir: String.t()
        }

  @doc "Runs every task in `dir` and returns per-task plus aggregate results."
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(dir, opts \\ []) when is_binary(dir) and is_list(opts) do
    samples = Keyword.get(opts, :samples, 1)
    ks = Keyword.get(opts, :ks, [1])

    with {:ok, tasks} <- EvalTask.load_dir(dir),
         true <- (is_integer(samples) and samples > 0) or {:error, :eval_bad_samples},
         true <- valid_ks?(ks) or {:error, :eval_bad_ks} do
      results = Enum.map(tasks, &run_task(&1, dir, samples, ks, opts))

      {:ok,
       %{
         dir: dir,
         samples: samples,
         ks: ks,
         tasks: results,
         aggregate: aggregate(results)
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
        curve =
          task.summary.pass_at_k
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map_join(" ", fn {k, v} -> "pass@#{k}=#{format_float(v)}" end)

        "  #{task.id}: #{task.summary.passed}/#{task.summary.samples} passed " <>
          "(rate=#{format_float(task.summary.pass_rate)} #{curve})"
      end)

    agg_curve =
      aggregate.pass_at_k
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(" ", fn {k, v} -> "pass@#{k}=#{format_float(v)}" end)

    footer =
      "aggregate: #{aggregate.passed}/#{aggregate.samples} passed " <>
        "(rate=#{format_float(aggregate.pass_rate)} #{agg_curve})"

    Enum.join([header | lines] ++ [footer], "\n")
  end

  defp run_task(%EvalTask{} = task, dir, samples, ks, opts) do
    loop_fn = Keyword.get(opts, :loop_fn, &default_loop_fn(&1, &2, &3, opts))
    on_sample = Keyword.get(opts, :on_sample, fn _task, _sample -> :ok end)

    results =
      for sample <- 1..samples do
        result = run_sample(task, dir, sample, loop_fn)
        on_sample.(task, result)
        result
      end

    outcomes = Enum.map(results, & &1.passed)

    %{
      id: task.id,
      samples: results,
      summary: Scoring.summarize(outcomes, ks)
    }
  end

  defp run_sample(%EvalTask{} = task, dir, sample, loop_fn) do
    fixture = Path.expand(task.repo, dir)
    workdir = Path.join(System.tmp_dir!(), "iex-eval-#{task.id}-#{sample}-#{uniq()}")

    with :ok <- prepare_workdir(fixture, workdir),
         {:loop, {:ok, outcome}} <- {:loop, loop_fn.(task.prompt, workdir, task)},
         {:grade, {:ok, grade}} <- {:grade, grade(task, workdir)} do
      %{sample: sample, passed: grade.passed, loop: outcome, grade: grade, workdir: workdir}
    else
      {:error, reason} ->
        %{sample: sample, passed: false, loop: nil, grade: nil, workdir: workdir, error: reason}

      {:loop, {:error, reason}} ->
        %{sample: sample, passed: false, loop: {:error, reason}, grade: nil, workdir: workdir}

      {:loop, other} ->
        %{sample: sample, passed: false, loop: other, grade: nil, workdir: workdir}

      {:grade, {:error, reason}} ->
        %{sample: sample, passed: false, loop: nil, grade: reason, workdir: workdir}
    end
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

    task_run = Task.async(fn -> System.cmd(cmd, args, cd: workdir, stderr_to_stdout: true) end)

    case Task.yield(task_run, task.timeout_ms) || Task.shutdown(task_run, :brutal_kill) do
      {:ok, {output, exit_code}} ->
        {:ok, %{passed: exit_code == 0, exit_code: exit_code, output: trim(output)}}

      {:exit, reason} ->
        {:error, {:eval_grade_crashed, reason}}

      nil ->
        {:error, :eval_grade_timeout}
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
         {:ok, run} <- Runs.claim_next_run("eval:#{uniq()}", lease_ms: 600_000) do
      AgentLoop.execute(run, workdir, fn _percent, _message -> :ok end,
        llm: llm,
        tool_executor: tool_executor,
        run_lease_owner: run.lease_owner,
        run_attempt: run.attempt,
        run_lease_generation: run.lease_generation,
        run_terminal_lease_ms: 600_000
      )
    end
  end

  defp aggregate(task_results) do
    outcomes = Enum.flat_map(task_results, fn task -> Enum.map(task.samples, & &1.passed) end)

    ks =
      task_results
      |> Enum.flat_map(fn task -> Map.keys(task.summary.pass_at_k) end)
      |> Enum.uniq()

    Scoring.summarize(outcomes, ks)
  end

  defp valid_ks?(ks), do: is_list(ks) and ks != [] and Enum.all?(ks, &(is_integer(&1) and &1 > 0))

  defp trim(output), do: String.slice(output || "", 0, 4_000)
  defp uniq, do: System.unique_integer([:positive])

  defp format_float(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 3)

  defp format_float(value), do: to_string(value)
end

defmodule IexCode.Engine.Agents.VerifierAgent do
  @moduledoc """
  Dedicated OTP GenServer subagent responsible for compilation verification,
  test suite execution via TestRunner, diagnostic parsing, and emitting structured verdicts.
  """
  use GenServer, restart: :transient
  require Logger
  alias IexCode.Consensus.{Arbitrator, Assessment}
  alias IexCode.Engine.{AgentCancellation, AgentRegistry, OperationManager}
  alias IexCode.{Sessions, Tools}
  alias IexCode.Tools.{TestRunner, TestSelector}
  alias IexCode.Tools.TestRunner.{CompilationError, Failure, Parser, StackFrame}

  @outer_timeout 90_000
  @inner_timeout 60_000
  @history_limit 20
  @lock_retry_interval 25
  @call_completion_margin 250
  @stdlib_apps ~w(elixir stdlib kernel ex_unit mix logger iex eex erl_eval)

  # Directories excluded from standalone workspace syntax validation
  @excluded_validate_dirs ~w(_build deps node_modules .git tmp)

  defmodule State do
    defstruct [
      :session_id,
      :session,
      :project_root,
      :control_token,
      status: :idle,
      current_op_id: nil,
      last_result: nil,
      history: []
    ]
  end

  # Client API

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    name =
      case {opts[:run_id], opts[:agent_id]} do
        {run_id, agent_id} when is_binary(run_id) and is_binary(agent_id) ->
          AgentRegistry.via_agent(run_id, agent_id)

        _ ->
          AgentRegistry.via_tuple(session_id, :verifier)
      end

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Runs full verification (compilation + test suite execution) for the project workspace.
  Returns `{:ok, summary}` on success or `{:error, {:verification_failed, diagnostics}}` on failure.
  """
  def verify(target, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @outer_timeout)
    GenServer.call(resolve_target(target), {:verify, opts}, timeout)
  end

  @doc """
  Runs the ExUnit test runner for the workspace.
  """
  def run_tests(target, test_opts \\ []) do
    timeout = Keyword.get(test_opts, :timeout, @outer_timeout)
    GenServer.call(resolve_target(target), {:run_tests, test_opts}, timeout)
  end

  @doc """
  Performs a compilation check in the workspace.
  """
  def check_compile(target, compile_opts \\ []) do
    timeout = Keyword.get(compile_opts, :timeout, 60_000)
    GenServer.call(resolve_target(target), {:check_compile, compile_opts}, timeout)
  end

  @doc """
  Returns the current internal state of the VerifierAgent.
  """
  def get_state(target) do
    GenServer.call(resolve_target(target), :get_state)
  end

  @doc """
  Enriches a verification diagnostics map with structured `critique_items`
  (`blocker` | `major`) and synthesized `actionable_feedback` produced via
  `IexCode.Consensus.Arbitrator.synthesize_actionable_feedback/2`, preserving
  all existing diagnostic keys.
  """
  @spec enrich_diagnostics(map(), Path.t() | nil) :: map()
  def enrich_diagnostics(%{} = diagnostics, project_root \\ nil) do
    do_enrich_diagnostics(diagnostics, project_root)
  end

  defp resolve_target(pid) when is_pid(pid), do: pid

  defp resolve_target(session_id) when is_binary(session_id) do
    AgentRegistry.via_tuple(session_id, :verifier)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    mark_fleet_owner(opts)
    session_id = Keyword.fetch!(opts, :session_id)
    session = opts[:session]

    project_root =
      opts[:project_root] || (session && session.project && session.project.root_path) ||
        File.cwd!()

    state = %State{
      session_id: session_id,
      session: session,
      project_root: project_root,
      control_token: opts[:control_token],
      status: :idle
    }

    unless is_binary(opts[:run_id]) do
      set_cancelled?(session_id, false)
      subscribe_steering(session_id)
    end

    {:ok, state}
  end

  defp mark_fleet_owner(opts) do
    if is_binary(opts[:run_id]) and is_binary(opts[:agent_id]) do
      Process.put(:iex_code_fleet_owner, IexCode.Engine.FleetRuntime.owner(opts))
      Process.put(:iex_code_fleet_control_token, opts[:control_token])

      AgentRegistry.put_agent_metadata(opts[:run_id], opts[:agent_id], %{
        role: :verifier,
        generation: opts[:generation]
      })
    end
  end

  @impl true
  def handle_call({:verify, opts}, _from, %State{} = state) do
    session_id = state.session_id
    project_root = opts[:project_root] || state.project_root
    parent_op_id = opts[:parent_op_id]
    project_id = trusted_project_id(opts, state)
    run_id = opts[:run_id]
    workspace_lock_delegation = opts[:workspace_lock_delegation]
    allowed_tools = Keyword.get(opts, :allowed_tools, :all)
    mix_exs_exists = File.exists?(Path.join(project_root, "mix.exs"))

    runtime_owner = Process.get(:iex_code_fleet_owner)

    verify_res =
      IexCode.Engine.FleetRuntime.run(runtime_owner, state.control_token, "verifying", fn ->
        OperationManager.run_sync_operation(
          session_id,
          parent_op_id,
          "VerifierAgent",
          "run_command",
          "Verifier: Checking compilation and test suite",
          %{command: if(mix_exs_exists, do: "mix compile", else: "standalone syntax validation")},
          fn progress ->
            if not tool_allowed?("run_command", allowed_tools) or
                 not tool_allowed?("run_tests", allowed_tools) do
              verification_error(
                :tool_not_allowed,
                "Verification tools are disabled by the run manifest",
                project_root
              )
            else
              if cancelled_fun(state).() do
                progress.(100, "Verification cancelled")

                verification_error(
                  :cancelled,
                  "Verification cancelled before it started",
                  project_root
                )
              else
                if mix_exs_exists do
                  progress.(20, "Running compilation check...")

                  compile_res =
                    OperationManager.run_sync_operation(
                      session_id,
                      parent_op_id,
                      "VerifierAgent",
                      "run_command",
                      "Verifier: mix compile check",
                      %{command: "mix compile"},
                      fn p ->
                        with_workspace_delegation(workspace_lock_delegation, fn ->
                          Tools.execute(
                            "run_command",
                            %{
                              "command" => "mix compile",
                              "timeout_ms" => 20_000,
                              "project_id" => project_id,
                              "run_id" => run_id,
                              "session_id" => session_id,
                              "agent_name" => "VerifierAgent",
                              "op_id" => parent_op_id
                            },
                            project_root,
                            p
                          )
                        end)
                      end
                    )

                  cond do
                    cancelled_fun(state).() ->
                      progress.(100, "Verification cancelled")

                      verification_error(
                        :cancelled,
                        "Verification cancelled before test run",
                        project_root
                      )

                    compile_failed?(compile_res) ->
                      progress.(90, "Evaluating verification verdict...")
                      evaluate_mix_verdict(compile_res, nil, project_root, progress)

                    true ->
                      test_runner_opts = [
                        project_root: project_root,
                        project_id: project_id,
                        run_id: run_id,
                        session_id: session_id,
                        timeout_ms: Keyword.get(opts, :test_timeout_ms, 30_000)
                      ]

                      test_runner_opts =
                        if opts[:test_file] do
                          test_runner_opts
                          |> Keyword.put(:file, opts[:test_file])
                          |> Keyword.put(:paths, List.wrap(opts[:test_file]))
                        else
                          test_runner_opts
                        end

                      run_mix_test_stages(
                        compile_res,
                        test_runner_opts,
                        opts,
                        state,
                        project_root,
                        workspace_lock_delegation,
                        progress
                      )
                  end
                else
                  progress.(40, "Validating Elixir files syntax in workspace...")
                  validate_standalone_workspace(project_root, progress)
                end
              end
            end
          end,
          Keyword.get(opts, :inner_timeout, @inner_timeout)
        )
      end)

    case verify_res do
      {:ok, summary_map} ->
        new_state = %State{
          state
          | status: :idle,
            last_result: summary_map,
            history: Enum.take([summary_map | state.history], @history_limit)
        }

        {:reply, {:ok, summary_map}, new_state}

      {:error, {:verification_failed, _}} = err ->
        new_state = %State{state | status: :idle, last_result: err}
        {:reply, err, new_state}

      # Normalize raw timeout/crash reasons into a structured verification failure
      {:error, reason} ->
        err =
          verification_error(
            reason,
            "Verification error: #{format_reason(reason)}",
            project_root
          )

        new_state = %State{state | status: :idle, last_result: err}
        {:reply, err, new_state}
    end
  end

  @impl true
  def handle_call({:run_tests, test_opts}, _from, %State{} = state) do
    opts =
      test_opts
      |> Keyword.put_new(:project_root, state.project_root)
      |> Keyword.put(:project_id, trusted_project_id(test_opts, state))
      |> Keyword.put(:session_id, state.session_id)

    res =
      with_workspace_delegation(test_opts[:workspace_lock_delegation], fn ->
        Tools.run_tests(opts)
      end)

    {:reply, res, state}
  end

  @impl true
  def handle_call({:check_compile, compile_opts}, _from, %State{} = state) do
    project_root = compile_opts[:project_root] || state.project_root
    session_id = compile_opts[:session_id] || state.session_id
    project_id = trusted_project_id(compile_opts, state)

    base_args = %{
      "command" => "mix compile",
      "project_id" => project_id,
      "run_id" => compile_opts[:run_id],
      "session_id" => session_id,
      "agent_name" => "VerifierAgent"
    }

    res =
      with_workspace_delegation(compile_opts[:workspace_lock_delegation], fn ->
        wait_timeout =
          compile_opts
          |> Keyword.get(:timeout, 60_000)
          |> Kernel.-(@call_completion_margin)
          |> max(0)

        retry_compile_lock_conflicts(
          fn remaining ->
            args = Map.put(base_args, "timeout_ms", max(1, min(30_000, remaining)))
            Tools.execute("run_command", args, project_root, fn _, _ -> :ok end)
          end,
          wait_timeout
        )
      end)

    {:reply, res, state}
  end

  @impl true
  def handle_call(:get_state, _from, %State{} = state) do
    {:reply, state, state}
  end

  defp trusted_project_id(opts, state) do
    if Keyword.get(opts, :isolated_worktree, false) == true do
      nil
    else
      (state.session && state.session.project_id) ||
        case Sessions.get_session(state.session_id) do
          %{project_id: project_id} -> project_id
          _ -> nil
        end
    end
  end

  defp with_workspace_delegation(nil, fun), do: fun.()

  defp with_workspace_delegation(delegation, fun) do
    IexCode.WorkspaceLocks.with_delegation(delegation, fun)
  end

  # A compile check is a cooperative verifier operation. Valid sessions sharing
  # one project serialize behind the project-exclusive command lock instead of
  # failing merely because another verifier got there first. The public
  # `run_tests/2` path intentionally remains fail-closed on a foreign lock.
  defp retry_compile_lock_conflicts(fun, wait_timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + wait_timeout_ms
    do_retry_compile_lock_conflicts(fun, deadline)
  end

  defp do_retry_compile_lock_conflicts(fun, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 1)

    case fun.(remaining) do
      {:error, {:workspace_lock_waiting, _locks}} = waiting ->
        retry_compile_after_conflict(fun, deadline, waiting)

      {:error, {:conflict, _locks}} = waiting ->
        retry_compile_after_conflict(fun, deadline, waiting)

      result ->
        result
    end
  end

  defp retry_compile_after_conflict(fun, deadline, waiting) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      receive do
      after
        min(@lock_retry_interval, remaining) -> do_retry_compile_lock_conflicts(fun, deadline)
      end
    else
      waiting
    end
  end

  # Steering / cancellation helpers

  defp subscribe_steering(session_id) do
    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session_id}:steer")
  end

  defp set_cancelled?(session_id, value) do
    AgentCancellation.set(__MODULE__, session_id, value)
  end

  defp cancelled_fun(%State{control_token: nil, session_id: session_id}) do
    fn -> AgentCancellation.cancelled?(session_id, __MODULE__) end
  end

  defp cancelled_fun(%State{control_token: token}) do
    fn -> IexCode.Engine.FleetControlToken.checkpoint(token) == :cancelled end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp tool_allowed?(_tool_name, :all), do: true
  defp tool_allowed?(_tool_name, nil), do: true

  defp tool_allowed?(tool_name, allowed_tools) when is_list(allowed_tools),
    do: tool_name in Enum.map(allowed_tools, &to_string/1)

  defp tool_allowed?(_tool_name, _allowed_tools), do: false

  defp compile_failed?({:ok, <<"Exit Code ", _::binary>>}), do: true
  defp compile_failed?({:error, _}), do: true
  defp compile_failed?(_), do: false

  defp test_run_failed?({:ok, %TestRunner.Result{status: status}})
       when status in [:failed, :compilation_error, :timeout, :error],
       do: true

  defp test_run_failed?({:error, test_err}) do
    err_str = if is_binary(test_err), do: test_err, else: inspect(test_err)
    not (Regex.match?(~r/\b0 failures\b/, err_str) or String.contains?(err_str, "No tests"))
  end

  defp test_run_failed?(_), do: false

  defp run_mix_test_stages(
         compile_res,
         test_runner_opts,
         opts,
         state,
         project_root,
         workspace_lock_delegation,
         progress
       ) do
    if Keyword.get(opts, :selective_preflight, false) == true do
      selector_opts =
        []
        |> maybe_put_opt(:changed_files, Keyword.get(opts, :changed_files))
        |> maybe_put_opt(:max_targets, Keyword.get(opts, :max_targets))

      case TestSelector.select(project_root, selector_opts) do
        {:ok, %{paths: [_ | _] = selected_paths} = selection} ->
          progress.(
            45,
            "Running selective preflight tests (#{length(selected_paths)} target(s))..."
          )

          preflight_opts = Keyword.put(test_runner_opts, :paths, selected_paths)

          preflight_res =
            with_workspace_delegation(workspace_lock_delegation, fn ->
              Tools.run_tests(preflight_opts)
            end)

          preflight_meta = %{
            enabled: true,
            selected_paths: selected_paths,
            changed_files: selection.changed_files,
            reasons: selection.reasons,
            modules: selection.modules
          }

          cond do
            test_run_failed?(preflight_res) ->
              progress.(90, "Selective preflight failed; emitting fast-fail diagnostics...")

              compile_res
              |> evaluate_mix_verdict(preflight_res, project_root, progress)
              |> attach_preflight_metadata(Map.put(preflight_meta, :fast_failed, true))

            cancelled_fun(state).() ->
              progress.(100, "Verification cancelled")

              verification_error(
                :cancelled,
                "Verification cancelled after selective preflight",
                project_root
              )

            Keyword.get(opts, :full_suite_after_preflight, true) == false or
                opts[:test_file] != nil ->
              progress.(90, "Evaluating selective preflight verdict...")

              compile_res
              |> evaluate_mix_verdict(preflight_res, project_root, progress)
              |> attach_preflight_metadata(
                Map.merge(preflight_meta, %{fast_failed: false, status: :passed})
              )

            true ->
              progress.(65, "Preflight passed; running full test suite...")

              full_res =
                with_workspace_delegation(workspace_lock_delegation, fn ->
                  Tools.run_tests(test_runner_opts)
                end)

              progress.(90, "Evaluating verification verdict...")

              compile_res
              |> evaluate_mix_verdict(full_res, project_root, progress)
              |> attach_preflight_metadata(
                Map.merge(preflight_meta, %{fast_failed: false, status: :passed})
              )
          end

        _no_targets ->
          progress.(60, "Running test suite...")

          test_res =
            with_workspace_delegation(workspace_lock_delegation, fn ->
              Tools.run_tests(test_runner_opts)
            end)

          progress.(90, "Evaluating verification verdict...")

          compile_res
          |> evaluate_mix_verdict(test_res, project_root, progress)
          |> attach_preflight_metadata(%{enabled: true, selected_paths: [], fast_failed: false})
      end
    else
      progress.(60, "Running test suite...")

      test_res =
        with_workspace_delegation(workspace_lock_delegation, fn ->
          Tools.run_tests(test_runner_opts)
        end)

      progress.(90, "Evaluating verification verdict...")
      evaluate_mix_verdict(compile_res, test_res, project_root, progress)
    end
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, val), do: Keyword.put(opts, key, val)

  defp attach_preflight_metadata({:ok, summary_map}, meta) when is_map(summary_map) do
    {:ok, Map.put(summary_map, :selective_preflight, meta)}
  end

  defp attach_preflight_metadata({:error, {:verification_failed, diag}}, meta)
       when is_map(diag) do
    {:error, {:verification_failed, Map.put(diag, :selective_preflight, meta)}}
  end

  defp attach_preflight_metadata(other, _meta), do: other

  defp verification_error(status, summary, project_root) do
    diag =
      %{
        status: status,
        summary: summary,
        failures: [],
        compilation_errors: [],
        compile_output: "",
        test_output: "",
        raw_output: summary
      }
      |> do_enrich_diagnostics(project_root)

    {:error, {:verification_failed, diag}}
  end

  defp evaluate_mix_verdict(compile_res, test_res, project_root, progress) do
    comp_text =
      case compile_res do
        {:ok, out} when is_binary(out) -> out
        {:error, err} when is_binary(err) -> err
        {:error, err} -> inspect(err)
        _ -> ""
      end

    case {compile_res, test_res} do
      # run_command reports non-zero exits as {:ok, "Exit Code N:\n..."} — treat as compile failure
      {{:ok, <<"Exit Code ", _::binary>> = comp_out}, _test_res} ->
        progress.(100, "Verification failed: mix compile exited non-zero")
        summary = "Compilation check failed:\n#{comp_out}"
        parsed_comp = parse_raw_compiler_errors(comp_out)
        comp_errors = if parsed_comp != [], do: parsed_comp, else: [%{message: comp_out}]

        diag =
          %{
            status: :compilation_error,
            summary: summary,
            failures: [],
            compilation_errors: comp_errors,
            compile_output: comp_out,
            test_output: "",
            raw_output: comp_out
          }
          |> do_enrich_diagnostics(project_root)

        {:error, {:verification_failed, diag}}

      {{:ok, comp_out}, {:ok, %TestRunner.Result{status: :passed} = res}} ->
        progress.(100, "Verification passed: All tests and compilation clean.")

        summary =
          "Compilation: OK\nTests: #{res.passed}/#{res.total} passed (#{res.duration_s}s)"

        {:ok,
         %{
           status: :passed,
           summary: summary,
           result: res,
           compile_output: comp_out,
           test_output: res.raw_output
         }}

      {{:ok, _comp_out}, {:ok, %TestRunner.Result{status: :failed} = res}} ->
        progress.(100, "Verification failed: #{res.failures_count} test failure(s)")
        summary = "Tests failed: #{res.failures_count}/#{res.total} failures"

        diag =
          %{
            status: :failed,
            summary: summary,
            failures: res.failures,
            compilation_errors: res.compilation_errors || [],
            compile_output: comp_text,
            test_output: res.raw_output,
            raw_output: res.raw_output,
            result: res
          }
          |> do_enrich_diagnostics(project_root)

        {:error, {:verification_failed, diag}}

      {{:ok, _comp_out}, {:ok, %TestRunner.Result{status: :compilation_error} = res}} ->
        progress.(100, "Verification failed: Compilation error detected during test run")
        summary = "Compilation error in tests: #{length(res.compilation_errors)} error(s)"

        diag =
          %{
            status: :compilation_error,
            summary: summary,
            failures: [],
            compilation_errors: res.compilation_errors,
            compile_output: comp_text,
            test_output: res.raw_output,
            raw_output: res.raw_output,
            result: res
          }
          |> do_enrich_diagnostics(project_root)

        {:error, {:verification_failed, diag}}

      {{:error, comp_err}, _} ->
        progress.(100, "Verification failed: mix compile error")
        err_str = if is_binary(comp_err), do: comp_err, else: inspect(comp_err)
        summary = "Compilation check failed:\n#{err_str}"
        parsed_comp = parse_raw_compiler_errors(err_str)
        comp_errors = if parsed_comp != [], do: parsed_comp, else: [%{message: err_str}]

        diag =
          %{
            status: :compilation_error,
            summary: summary,
            failures: [],
            compilation_errors: comp_errors,
            compile_output: err_str,
            test_output: "",
            raw_output: err_str
          }
          |> do_enrich_diagnostics(project_root)

        {:error, {:verification_failed, diag}}

      {_, {:error, test_err}} ->
        err_str = if is_binary(test_err), do: test_err, else: inspect(test_err)
        # If mix test failed with non-zero exit or no tests found
        # (word-boundary match so "10 failures" is not mistaken for "0 failures")
        if Regex.match?(~r/\b0 failures\b/, err_str) or String.contains?(err_str, "No tests") do
          progress.(100, "Verification clean (no test failures)")

          {:ok,
           %{
             status: :passed,
             summary: "Compilation OK, no test failures",
             compile_output: comp_text,
             test_output: err_str
           }}
        else
          progress.(100, "Verification failed with error")
          summary = "Test execution error: #{err_str}"

          diag =
            %{
              status: :failed,
              summary: summary,
              failures: [],
              compilation_errors: [],
              compile_output: comp_text,
              test_output: err_str,
              raw_output: err_str
            }
            |> do_enrich_diagnostics(project_root)

          {:error, {:verification_failed, diag}}
        end
    end
  end

  # run_command wraps non-zero exits as {:ok, "Exit Code N:\n<output>"}
  defp validate_standalone_workspace(project_root, progress) do
    elixir_files =
      Path.wildcard(Path.join(project_root, "**/*.{ex,exs}"))
      |> Enum.reject(fn p ->
        rel = Path.relative_to(p, project_root)
        List.first(Path.split(rel)) in @excluded_validate_dirs
      end)

    if elixir_files == [] do
      progress.(100, "Verification clean (no Elixir files present)")
      {:ok, %{status: :passed, summary: "No Elixir files found to compile", compile_output: ""}}
    else
      results =
        Enum.map(elixir_files, fn file_path ->
          case File.read(file_path) do
            {:ok, content} ->
              check_file_syntax(content, file_path)

            {:error, reason} ->
              {:error,
               %{
                 file: file_path,
                 line: 1,
                 message: "Failed to read file: #{inspect(reason)}"
               }}
          end
        end)

      errors =
        Enum.flat_map(results, fn
          {:error, err} -> [err]
          _ -> []
        end)

      if errors == [] do
        progress.(
          100,
          "Verification passed: All #{length(elixir_files)} files syntactically valid."
        )

        summary = "Syntax check: OK (#{length(elixir_files)} file(s) checked)"
        {:ok, %{status: :passed, summary: summary, compile_output: summary}}
      else
        first_err = List.first(errors)
        progress.(100, "Verification failed: #{length(errors)} syntax error(s)")

        summary =
          "Compilation check failed in #{first_err.file}:#{first_err.line}: #{first_err.message}"

        comp_errors =
          Enum.map(errors, fn err ->
            %CompilationError{
              error_type: "SyntaxError",
              file: err.file,
              line: err.line,
              message: err.message,
              raw: "Compilation check failed in #{err.file}:#{err.line}: #{err.message}"
            }
          end)

        diag =
          %{
            status: :compilation_error,
            summary: summary,
            failures: [],
            compilation_errors: comp_errors,
            compile_output: summary,
            test_output: "",
            raw_output: summary
          }
          |> do_enrich_diagnostics(project_root)

        {:error, {:verification_failed, diag}}
      end
    end
  end

  defp do_enrich_diagnostics(%{} = diag, project_root) do
    existing_items =
      case Map.get(diag, :critique_items) do
        items when is_list(items) and items != [] -> items
        _ -> extract_critique_items(diag, project_root)
      end

    actionable_feedback =
      case Map.get(diag, :actionable_feedback) do
        %{repair_prompt: prompt} = fb when is_binary(prompt) and prompt != "" ->
          fb

        _ ->
          synthesize_verifier_feedback(diag, existing_items)
      end

    diag
    |> Map.put_new(:compile_output, Map.get(diag, :raw_output, "") || "")
    |> Map.put_new(:test_output, Map.get(diag, :raw_output, "") || "")
    |> Map.put(:critique_items, existing_items)
    |> Map.put(:actionable_feedback, actionable_feedback)
  end

  defp synthesize_verifier_feedback(diag, critique_items) do
    has_blocker? =
      Map.get(diag, :status) == :compilation_error or
        Enum.any?(critique_items, fn item ->
          Map.get(item, :severity) in ["blocker", :blocker] or
            Map.get(item, "severity") == "blocker"
        end)

    vote = if has_blocker?, do: :reject, else: :request_changes

    assessment = %Assessment{
      reviewer_id: "verifier_agent",
      provider: "local",
      model: "ex_unit_compiler",
      vote: vote,
      confidence: 1.0,
      scores: %{
        correctness: if(has_blocker?, do: 0.15, else: 0.40),
        security: 0.85,
        architectural_fit: 0.80,
        maintainability: 0.75,
        testability: 0.45
      },
      verdict_reason: to_string(Map.get(diag, :summary, "Verification failed")),
      critique_points: critique_items,
      suggested_modifications: build_suggested_modifications(critique_items)
    }

    Arbitrator.synthesize_actionable_feedback([assessment])
  end

  defp build_suggested_modifications(critique_items) when is_list(critique_items) do
    critique_items
    |> Enum.take(6)
    |> Enum.map(fn item ->
      file = Map.get(item, :file) || Map.get(item, "file")
      line = Map.get(item, :line) || Map.get(item, "line")
      desc = Map.get(item, :description) || Map.get(item, "description") || "Resolve diagnostic"

      loc =
        cond do
          is_binary(file) and is_integer(line) and line > 0 -> "#{file}:#{line}"
          is_binary(file) -> file
          true -> "workspace"
        end

      "Fix #{loc} — #{desc}"
    end)
  end

  defp extract_critique_items(diag, project_root) do
    comp_items = extract_compiler_critique_items(diag, project_root)
    failure_items = extract_failure_critique_items(diag, project_root)
    combined = dedup_and_rank_critique_items(comp_items ++ failure_items)

    if combined != [] do
      combined
    else
      fallback_severity =
        if Map.get(diag, :status) == :compilation_error, do: "blocker", else: "major"

      raw_desc =
        Map.get(diag, :summary) ||
          Map.get(diag, :raw_output) ||
          Map.get(diag, :compile) ||
          inspect(Map.drop(diag, [:actionable_feedback, :critique_items, :result]))

      [
        %{
          severity: fallback_severity,
          category: "correctness",
          file: nil,
          line: nil,
          description: compact_diagnostic_text(to_string(raw_desc))
        }
      ]
    end
  end

  defp extract_compiler_critique_items(diag, project_root) do
    raw_errors = Map.get(diag, :compilation_errors, []) || []
    compile_out = Map.get(diag, :compile_output) || Map.get(diag, :raw_output) || ""

    from_structs =
      Enum.flat_map(raw_errors, fn
        %CompilationError{file: file, line: line, error_type: err_type, message: msg} ->
          [
            %{
              severity: "blocker",
              category: "correctness",
              file: normalize_diag_file(file, project_root),
              line: normalize_diag_line(line),
              description: format_compiler_description(err_type, msg)
            }
          ]

        %{file: file, line: line, message: msg} ->
          [
            %{
              severity: "blocker",
              category: "correctness",
              file: normalize_diag_file(file, project_root),
              line: normalize_diag_line(line),
              description: compact_diagnostic_text(to_string(msg))
            }
          ]

        %{message: msg} when is_binary(msg) ->
          parsed = parse_raw_compiler_errors(msg)

          if parsed != [] do
            Enum.map(parsed, fn ce ->
              %{
                severity: "blocker",
                category: "correctness",
                file: normalize_diag_file(ce.file, project_root),
                line: normalize_diag_line(ce.line),
                description: format_compiler_description(ce.error_type, ce.message)
              }
            end)
          else
            []
          end

        _ ->
          []
      end)

    from_raw =
      if Map.get(diag, :status) == :compilation_error and is_binary(compile_out) and
           compile_out != "" do
        compile_out
        |> parse_raw_compiler_errors()
        |> Enum.map(fn ce ->
          %{
            severity: "blocker",
            category: "correctness",
            file: normalize_diag_file(ce.file, project_root),
            line: normalize_diag_line(ce.line),
            description: format_compiler_description(ce.error_type, ce.message)
          }
        end)
      else
        []
      end

    items = from_structs ++ from_raw

    # Drop line-nil entries when we already parsed a line-numbered entry for the same file
    files_with_lines =
      items
      |> Enum.filter(&(is_binary(&1.file) and is_integer(&1.line)))
      |> MapSet.new(& &1.file)

    Enum.reject(items, fn item ->
      is_binary(item.file) and is_nil(item.line) and MapSet.member?(files_with_lines, item.file)
    end)
  end

  defp parse_raw_compiler_errors(raw_text) when is_binary(raw_text) do
    clean = Parser.strip_ansi(raw_text)
    base = Parser.parse_compilation_errors(clean)

    # Modern Elixir 1.15+ diagnostic format:
    #   error: <msg>
    #   ...
    #   └─ lib/foo.ex:12:5: ...
    modern_blocks =
      Regex.scan(
        ~r/error:\s*([^\n]+)\n(?:(?!\n\s*error:).*\n)*?\s*(?:└─|-->)\s*([^\s:]+):(\d+)(?::(\d+))?/u,
        clean
      )
      |> Enum.map(fn
        [raw, msg, file, line_str, col_str] ->
          %CompilationError{
            error_type: "CompileError",
            file: String.trim(file),
            line: String.to_integer(line_str),
            column: if(col_str != "", do: String.to_integer(col_str), else: nil),
            message: String.trim(msg),
            raw: raw
          }

        [raw, msg, file, line_str] ->
          %CompilationError{
            error_type: "CompileError",
            file: String.trim(file),
            line: String.to_integer(line_str),
            column: nil,
            message: String.trim(msg),
            raw: raw
          }
      end)

    # Direct `path/to/file.ex:12: ...` compiler lines
    colon_lines =
      Regex.scan(
        ~r/(?:^|\n)\s*([A-Za-z0-9_.\-\/]+\.exs?):(\d+)(?::(\d+))?:\s*(?:error:\s*)?([^\n]+)/,
        clean
      )
      |> Enum.map(fn
        [raw, file, line_str, col_str, msg] ->
          %CompilationError{
            error_type: "CompileError",
            file: String.trim(file),
            line: String.to_integer(line_str),
            column: if(col_str != "", do: String.to_integer(col_str), else: nil),
            message: String.trim(msg),
            raw: raw
          }
      end)

    (modern_blocks ++ base ++ colon_lines)
    |> Enum.uniq_by(&{&1.file, &1.line, &1.message})
  end

  defp extract_failure_critique_items(diag, project_root) do
    failures =
      case Map.get(diag, :failures) do
        list when is_list(list) and list != [] ->
          list

        _ ->
          case Map.get(diag, :result) do
            %TestRunner.Result{failures: list} when is_list(list) -> list
            _ -> []
          end
      end

    raw_parsed =
      if failures == [] and Map.get(diag, :status) == :failed do
        raw = Map.get(diag, :test_output) || Map.get(diag, :raw_output) || ""

        if is_binary(raw) and raw != "",
          do: Parser.parse_failures(Parser.strip_ansi(raw)),
          else: []
      else
        failures
      end

    Enum.map(raw_parsed, fn
      %Failure{} = f ->
        {chosen_file, chosen_line} = select_failure_location(f, project_root)
        desc = format_failure_description(f, chosen_file, project_root)

        %{
          severity: "major",
          category: "correctness",
          file: chosen_file,
          line: chosen_line,
          description: desc
        }

      %{} = map ->
        file =
          normalize_diag_file(
            Map.get(map, :file) || Map.get(map, "file"),
            project_root
          )

        line = normalize_diag_line(Map.get(map, :line) || Map.get(map, "line"))
        msg = Map.get(map, :message) || Map.get(map, "message") || inspect(map)

        %{
          severity: "major",
          category: "correctness",
          file: file,
          line: line,
          description: compact_diagnostic_text(to_string(msg))
        }
    end)
  end

  defp select_failure_location(%Failure{} = failure, project_root) do
    frames = failure.stacktrace || []

    workspace_lib_frame =
      Enum.find(frames, fn
        %StackFrame{app: app, file: file, line: line}
        when is_binary(file) and is_integer(line) and line > 0 ->
          app not in @stdlib_apps and
            workspace_lib_path?(file, project_root)

        _ ->
          false
      end)

    workspace_any_frame =
      Enum.find(frames, fn
        %StackFrame{app: app, file: file, line: line}
        when is_binary(file) and is_integer(line) and line > 0 ->
          app not in @stdlib_apps and
            workspace_contained_path?(file, project_root)

        _ ->
          false
      end)

    cond do
      workspace_lib_frame != nil ->
        {
          normalize_diag_file(workspace_lib_frame.file, project_root),
          normalize_diag_line(workspace_lib_frame.line)
        }

      workspace_any_frame != nil ->
        {
          normalize_diag_file(workspace_any_frame.file, project_root),
          normalize_diag_line(workspace_any_frame.line)
        }

      is_binary(failure.file) ->
        {
          normalize_diag_file(failure.file, project_root),
          normalize_diag_line(failure.line)
        }

      true ->
        {nil, nil}
    end
  end

  defp workspace_lib_path?(file, project_root) do
    rel = normalize_diag_file(file, project_root)

    is_binary(rel) and
      String.starts_with?(rel, "lib/") and
      workspace_contained_path?(file, project_root)
  end

  defp workspace_contained_path?(file, nil) when is_binary(file) do
    not String.starts_with?(file, "deps/") and not String.starts_with?(file, "_build/")
  end

  defp workspace_contained_path?(file, project_root)
       when is_binary(file) and is_binary(project_root) do
    rel = normalize_diag_file(file, project_root)

    is_binary(rel) and
      not String.starts_with?(rel, "..") and
      not String.starts_with?(rel, "/") and
      not String.starts_with?(rel, "deps/") and
      not String.starts_with?(rel, "_build/") and
      File.exists?(Path.join(project_root, rel))
  end

  defp normalize_diag_file(nil, _project_root), do: nil
  defp normalize_diag_file("", _project_root), do: nil
  defp normalize_diag_file("nofile", _project_root), do: nil

  defp normalize_diag_file(file, project_root) when is_binary(file) do
    trimmed = String.trim(file)

    cond do
      trimmed in ["", "nofile"] ->
        nil

      is_binary(project_root) and Path.type(trimmed) == :absolute ->
        rel_direct = Path.relative_to(trimmed, project_root)

        if rel_direct != trimmed and not String.starts_with?(rel_direct, "..") do
          rel_direct
        else
          rel_expanded = Path.relative_to(Path.expand(trimmed), Path.expand(project_root))

          if rel_expanded != Path.expand(trimmed) and not String.starts_with?(rel_expanded, "..") do
            rel_expanded
          else
            trimmed
          end
        end

      true ->
        String.trim_leading(trimmed, "./")
    end
  end

  defp normalize_diag_line(line) when is_integer(line) and line > 0, do: line
  defp normalize_diag_line(_), do: nil

  defp format_compiler_description(err_type, msg) do
    clean_msg = compact_diagnostic_text(to_string(msg || "Compilation error"))

    if is_binary(err_type) and err_type != "" and not String.contains?(clean_msg, err_type) do
      "#{err_type}: #{clean_msg}"
    else
      clean_msg
    end
  end

  defp format_failure_description(%Failure{} = f, chosen_file, project_root) do
    test_loc =
      case {normalize_diag_file(f.file, project_root), normalize_diag_line(f.line)} do
        {tf, tl} when is_binary(tf) and is_integer(tl) and tf != chosen_file ->
          " [from #{tf}:#{tl}]"

        _ ->
          ""
      end

    assertion_diff =
      cond do
        is_binary(f.left) and is_binary(f.right) ->
          " (left: #{f.left}, right: #{f.right})"

        is_binary(f.code_snippet) ->
          " (code: #{f.code_snippet})"

        true ->
          ""
      end

    msg = if is_binary(f.message) and f.message != "", do: f.message, else: "Assertion failed"

    compact_diagnostic_text("#{f.module} — #{f.test_name}: #{msg}#{assertion_diff}#{test_loc}")
  end

  defp compact_diagnostic_text(text) when is_binary(text) do
    text
    |> Parser.strip_ansi()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 320)
  end

  defp dedup_and_rank_critique_items(items) do
    items
    |> Enum.uniq_by(fn item ->
      {item.severity, item.file, item.line, item.description}
    end)
    |> Enum.sort_by(fn item ->
      sev_rank = if item.severity == "blocker", do: 0, else: 1
      {sev_rank, item.file || "~", item.line || 999_999, item.description}
    end)
  end

  # Syntax-only validation: parse to quoted form without compiling into the app BEAM.
  defp check_file_syntax(content, file_path) do
    try do
      case Code.string_to_quoted(content, file: file_path) do
        {:ok, _ast} ->
          {:ok, file_path}

        {:error, {meta, message, token}} ->
          line =
            cond do
              is_list(meta) -> Keyword.get(meta, :line, 1)
              is_integer(meta) -> meta
              true -> 1
            end

          token_str =
            cond do
              is_binary(token) -> token
              is_list(token) -> to_string(token)
              true -> inspect(token)
            end

          msg =
            case message do
              {prefix, suffix} -> "#{prefix}#{suffix}#{token_str}"
              m when is_binary(m) -> "#{m}#{token_str}"
              other -> "#{inspect(other)}#{token_str}"
            end

          {:error, %{file: file_path, line: line, message: msg}}

        {:error, other} ->
          {:error, %{file: file_path, line: 1, message: inspect(other)}}
      end
    rescue
      e ->
        {:error, %{file: file_path, line: 1, message: format_exception_message(e)}}
    catch
      kind, term ->
        {:error, %{file: file_path, line: 1, message: "#{kind}: #{inspect(term)}"}}
    end
  end

  @impl true
  def handle_info({:cancel, session_id, _opts}, state) do
    set_cancelled?(session_id, true)
    {:noreply, state}
  end

  @impl true
  def handle_info({:pause, session_id}, state) do
    set_cancelled?(session_id, true)
    {:noreply, state}
  end

  @impl true
  def handle_info({:resume, session_id}, state) do
    set_cancelled?(session_id, false)
    {:noreply, state}
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:operation_task_done, _op_id, _result}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp format_exception_message(%SyntaxError{description: {prefix, suffix}}) do
    "#{prefix}#{suffix}"
  end

  defp format_exception_message(%SyntaxError{description: desc}) when is_binary(desc) do
    desc
  end

  defp format_exception_message(e) when is_exception(e) do
    try do
      Exception.message(e)
    rescue
      _ -> inspect(e)
    end
  end

  defp format_exception_message(other), do: inspect(other)
end

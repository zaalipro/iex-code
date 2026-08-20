defmodule IexCode.Engine.Agents.VerifierAgent do
  @moduledoc """
  Dedicated OTP GenServer subagent responsible for compilation verification,
  test suite execution via TestRunner, diagnostic parsing, and emitting structured verdicts.
  """
  use GenServer, restart: :transient
  require Logger
  alias IexCode.Engine.{AgentRegistry, OperationManager}
  alias IexCode.Tools
  alias IexCode.Tools.TestRunner

  defmodule State do
    defstruct [
      :session_id,
      :session,
      :project_root,
      status: :idle,
      current_op_id: nil,
      last_result: nil,
      history: []
    ]
  end

  # Client API

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: AgentRegistry.via_tuple(session_id, :verifier))
  end

  @doc """
  Runs full verification (compilation + test suite execution) for the project workspace.
  Returns `{:ok, summary}` on success or `{:error, {:verification_failed, diagnostics}}` on failure.
  """
  def verify(target, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(resolve_target(target), {:verify, opts}, timeout)
  end

  @doc """
  Runs the ExUnit test runner for the workspace.
  """
  def run_tests(target, test_opts \\ []) do
    timeout = Keyword.get(test_opts, :timeout, 60_000)
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

  defp resolve_target(pid) when is_pid(pid), do: pid

  defp resolve_target(session_id) when is_binary(session_id) do
    AgentRegistry.via_tuple(session_id, :verifier)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    session = opts[:session]

    project_root =
      opts[:project_root] || (session && session.project && session.project.root_path) ||
        File.cwd!()

    state = %State{
      session_id: session_id,
      session: session,
      project_root: project_root,
      status: :idle
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:verify, opts}, _from, %State{} = state) do
    session_id = state.session_id
    project_root = opts[:project_root] || state.project_root
    parent_op_id = opts[:parent_op_id]
    mix_exs_exists = File.exists?(Path.join(project_root, "mix.exs"))

    verify_res =
      OperationManager.run_sync_operation(
        session_id,
        parent_op_id,
        "VerifierAgent",
        "run_command",
        "Verifier: Checking compilation and test suite",
        %{command: if(mix_exs_exists, do: "mix compile", else: "standalone syntax validation")},
        fn progress ->
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
                  Tools.execute(
                    "run_command",
                    %{"command" => "mix compile", "timeout_ms" => 20_000},
                    project_root,
                    p
                  )
                end
              )

            progress.(60, "Running test suite...")

            test_runner_opts = [
              project_root: project_root,
              timeout_ms: Keyword.get(opts, :test_timeout_ms, 30_000)
            ]

            test_runner_opts =
              if opts[:test_file],
                do: Keyword.put(test_runner_opts, :file, opts[:test_file]),
                else: test_runner_opts

            test_res = TestRunner.run(test_runner_opts)

            progress.(90, "Evaluating verification verdict...")

            evaluate_mix_verdict(compile_res, test_res, progress)
          else
            progress.(40, "Validating Elixir files syntax in workspace...")
            validate_standalone_workspace(project_root, progress)
          end
        end,
        Keyword.get(opts, :timeout, 60_000)
      )

    case verify_res do
      {:ok, summary_map} ->
        new_state = %State{
          state
          | status: :idle,
            last_result: summary_map,
            history: [summary_map | state.history]
        }

        {:reply, {:ok, summary_map}, new_state}

      {:error, reason} ->
        new_state = %State{state | status: :idle, last_result: {:error, reason}}
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call({:run_tests, test_opts}, _from, %State{} = state) do
    opts = Keyword.put_new(test_opts, :project_root, state.project_root)
    res = TestRunner.run(opts)
    {:reply, res, state}
  end

  @impl true
  def handle_call({:check_compile, compile_opts}, _from, %State{} = state) do
    project_root = compile_opts[:project_root] || state.project_root

    res =
      Tools.execute("run_command", %{"command" => "mix compile"}, project_root, fn _, _ -> :ok end)

    {:reply, res, state}
  end

  @impl true
  def handle_call(:get_state, _from, %State{} = state) do
    {:reply, state, state}
  end

  defp evaluate_mix_verdict(compile_res, test_res, progress) do
    case {compile_res, test_res} do
      {{:ok, comp_out}, {:ok, %TestRunner.Result{status: :passed} = res}} ->
        progress.(100, "Verification passed: All tests and compilation clean.")

        summary =
          "Compilation: OK\nTests: #{res.passed}/#{res.total} passed (#{res.duration_s}s)"

        {:ok, %{status: :passed, summary: summary, result: res, compile_output: comp_out}}

      {{:ok, _comp_out}, {:ok, %TestRunner.Result{status: :failed} = res}} ->
        progress.(100, "Verification failed: #{res.failures_count} test failure(s)")
        summary = "Tests failed: #{res.failures_count}/#{res.total} failures"

        {:error,
         {:verification_failed,
          %{
            status: :failed,
            summary: summary,
            failures: res.failures,
            compilation_errors: [],
            raw_output: res.raw_output,
            result: res
          }}}

      {{:ok, _comp_out}, {:ok, %TestRunner.Result{status: :compilation_error} = res}} ->
        progress.(100, "Verification failed: Compilation error detected during test run")
        summary = "Compilation error in tests: #{length(res.compilation_errors)} error(s)"

        {:error,
         {:verification_failed,
          %{
            status: :compilation_error,
            summary: summary,
            failures: [],
            compilation_errors: res.compilation_errors,
            raw_output: res.raw_output,
            result: res
          }}}

      {{:error, comp_err}, _} ->
        progress.(100, "Verification failed: mix compile error")
        err_str = if is_binary(comp_err), do: comp_err, else: inspect(comp_err)
        summary = "Compilation check failed:\n#{err_str}"

        {:error,
         {:verification_failed,
          %{
            status: :compilation_error,
            summary: summary,
            failures: [],
            compilation_errors: [%{message: err_str}],
            raw_output: err_str
          }}}

      {_, {:error, test_err}} ->
        err_str = if is_binary(test_err), do: test_err, else: inspect(test_err)
        # If mix test failed with non-zero exit or no tests found
        if String.contains?(err_str, "0 failures") or String.contains?(err_str, "No tests") do
          progress.(100, "Verification clean (no test failures)")

          {:ok,
           %{
             status: :passed,
             summary: "Compilation OK, no test failures",
             compile_output: ""
           }}
        else
          progress.(100, "Verification failed with error")
          summary = "Test execution error: #{err_str}"

          {:error,
           {:verification_failed,
            %{
              status: :failed,
              summary: summary,
              failures: [],
              compilation_errors: [],
              raw_output: err_str
            }}}
        end
    end
  end

  defp validate_standalone_workspace(project_root, progress) do
    elixir_files =
      Path.wildcard(Path.join(project_root, "**/*.{ex,exs}"))

    if elixir_files == [] do
      progress.(100, "Verification clean (no Elixir files present)")
      {:ok, %{status: :passed, summary: "No Elixir files found to compile", compile_output: ""}}
    else
      results =
        Enum.map(elixir_files, fn file_path ->
          content = File.read!(file_path)

          case Code.string_to_quoted(content, file: file_path) do
            {:ok, _ast} ->
              try do
                modules = Code.compile_string(content, file_path)

                for {mod, _bin} <- modules do
                  :code.purge(mod)
                  :code.delete(mod)
                end

                {:ok, file_path}
              rescue
                e ->
                  line =
                    if is_map(e) and Map.has_key?(e, :line), do: Map.get(e, :line) || 1, else: 1

                  {:error, %{file: file_path, line: line, message: format_exception_message(e)}}
              catch
                kind, term ->
                  {:error, %{file: file_path, line: 1, message: "#{kind}: #{inspect(term)}"}}
              end

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

        {:error,
         {:verification_failed,
          %{
            status: :compilation_error,
            summary: summary,
            failures: [],
            compilation_errors: [
              %IexCode.Tools.TestRunner.CompilationError{
                error_type: "SyntaxError",
                file: first_err.file,
                line: first_err.line,
                message: first_err.message,
                raw: summary
              }
            ],
            raw_output: summary
          }}}
      end
    end
  end

  @impl true
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

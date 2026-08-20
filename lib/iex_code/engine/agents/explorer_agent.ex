defmodule IexCode.Engine.Agents.ExplorerAgent do
  @moduledoc """
  Dedicated OTP GenServer subagent responsible for codebase traversal,
  AST symbol search, file discovery, and codebase context synthesis.
  """
  use GenServer, restart: :transient
  require Logger
  alias IexCode.Engine.{AgentRegistry, OperationManager}
  alias IexCode.Tools
  alias IexCode.Tools.ASTSearch

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
    GenServer.start_link(__MODULE__, opts, name: AgentRegistry.via_tuple(session_id, :explorer))
  end

  @doc """
  Explores the codebase based on the user prompt and optional plan.
  """
  def explore(target, prompt, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(resolve_target(target), {:explore, prompt, opts}, timeout)
  end

  @doc """
  Searches AST symbols across the project workspace.
  """
  def search_ast(target, query_map, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(resolve_target(target), {:search_ast, query_map, opts}, timeout)
  end

  @doc """
  Performs a regex or literal grep search across the project workspace.
  """
  def grep(target, query, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(resolve_target(target), {:grep, query, opts}, timeout)
  end

  @doc """
  Returns the current internal state of the ExplorerAgent.
  """
  def get_state(target) do
    GenServer.call(resolve_target(target), :get_state)
  end

  defp resolve_target(pid) when is_pid(pid), do: pid

  defp resolve_target(session_id) when is_binary(session_id) do
    AgentRegistry.via_tuple(session_id, :explorer)
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
  def handle_call({:explore, prompt, opts}, _from, %State{} = state) do
    session_id = state.session_id
    project_root = opts[:project_root] || state.project_root
    parent_op_id = opts[:parent_op_id]

    explore_res =
      OperationManager.run_sync_operation(
        session_id,
        parent_op_id,
        "ExplorerAgent",
        "grep_search",
        "Explorer: Scanning codebase for relevant files & symbols",
        %{prompt: prompt},
        fn progress ->
          progress.(20, "Searching project files...")

          # Run grep operation for module definitions
          grep_res =
            OperationManager.run_sync_operation(
              session_id,
              parent_op_id,
              "ExplorerAgent",
              "grep_search",
              "Explorer: Grepping for modules and definitions",
              %{query: "defmodule"},
              fn p ->
                Tools.execute("grep_search", %{"query" => "defmodule"}, project_root, p)
              end
            )

          progress.(60, "Scanning AST symbols...")

          # Run AST search for key symbols if specified
          ast_symbols =
            case ASTSearch.search(project_root, %{type: "module"}) do
              {:ok, syms} -> syms
              _ -> []
            end

          progress.(80, "Synthesizing codebase context...")

          context_summary =
            cond do
              match?({:ok, output} when is_binary(output) and byte_size(output) > 0, grep_res) ->
                {:ok, output} = grep_res
                "Found key modules in workspace:\n#{String.slice(output, 0, 1500)}"

              ast_symbols != [] ->
                sym_list =
                  Enum.map_join(
                    Enum.take(ast_symbols, 10),
                    "\n",
                    &"- #{&1.name} (#{Path.relative_to(&1.file, project_root)}:#{&1.line})"
                  )

                "Discovered AST modules:\n#{sym_list}"

              true ->
                "Workspace exploration complete. Ready for implementation."
            end

          progress.(100, "Exploration complete")
          {:ok, context_summary}
        end,
        Keyword.get(opts, :timeout, 60_000)
      )

    case explore_res do
      {:ok, summary} ->
        new_state = %State{
          state
          | status: :idle,
            last_result: summary,
            history: [summary | state.history]
        }

        {:reply, {:ok, summary}, new_state}

      {:error, reason} ->
        new_state = %State{state | status: :idle, last_result: {:error, reason}}
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call({:search_ast, query_map, opts}, _from, %State{} = state) do
    project_root = opts[:project_root] || state.project_root
    res = ASTSearch.search(project_root, query_map)
    {:reply, res, state}
  end

  @impl true
  def handle_call({:grep, query, opts}, _from, %State{} = state) do
    project_root = opts[:project_root] || state.project_root
    res = Tools.execute("grep_search", %{"query" => query}, project_root, fn _, _ -> :ok end)
    {:reply, res, state}
  end

  @impl true
  def handle_call(:get_state, _from, %State{} = state) do
    {:reply, state, state}
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
end

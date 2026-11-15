defmodule IexCode.Engine.Agents.ExplorerAgent do
  @moduledoc """
  Dedicated OTP GenServer subagent responsible for codebase traversal,
  AST symbol search, file discovery, and codebase context synthesis.
  """
  use GenServer, restart: :transient
  require Logger
  alias IexCode.Engine.{AgentCancellation, AgentRegistry, OperationManager}
  alias IexCode.SemanticIndex.Indexer
  alias IexCode.Tools
  alias IexCode.Tools.{ASTSearch, RepoMap, SymbolRefactor}

  @outer_timeout 90_000
  @inner_timeout 60_000
  @history_limit 20
  @max_context_summary_bytes 4_500
  @repo_map_max_bytes 3_000
  @search_text_scan_limit 8_000
  @max_symbol_candidates 3

  @stopwords ~w(the and for with this that from into your you are have has will would should could
                implement create make code file files please using used when then them they what
                which there here about after before between during through under over need wants)

  @prompt_verbs MapSet.new(~w(
    Inspect Explore Implement Fix Refactor Update Create Add Remove Check Verify Analyze
    Search Run Test Find Build Ensure Support Upgrade Write Read Please Explorer Shard
    All Some Key Workspace Module Modules Function Functions File Files Code Task Plan
  ))

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
          AgentRegistry.via_tuple(session_id, :explorer)
      end

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Explores the codebase based on the user prompt and optional plan.
  """
  def explore(target, prompt, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @outer_timeout)
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
  Executes a shell command in the context of the ExplorerAgent.
  """
  def run_command(target, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(resolve_target(target), {:run_command, command, opts}, timeout)
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
        role: :explorer,
        generation: opts[:generation]
      })
    end
  end

  @impl true
  def handle_call({:explore, prompt, opts}, _from, %State{} = state) do
    session_id = state.session_id
    project_root = opts[:project_root] || state.project_root
    parent_op_id = opts[:parent_op_id]
    allowed_tools = Keyword.get(opts, :allowed_tools, :all)

    runtime_owner = Process.get(:iex_code_fleet_owner)

    explore_res =
      IexCode.Engine.FleetRuntime.run(runtime_owner, state.control_token, "exploring", fn ->
        OperationManager.run_sync_operation(
          session_id,
          parent_op_id,
          "ExplorerAgent",
          "grep_search",
          "Explorer: Scanning codebase for relevant files & symbols",
          %{prompt: prompt},
          fn progress ->
            if cancelled_fun(state).() do
              {:error, :cancelled}
            else
              progress.(20, "Searching project files...")

              # Derive the grep and focus queries from a bounded slice of prompt + steering
              search_text =
                [prompt | Keyword.get(opts, :steer_directives, [])]
                |> Enum.join("\n")
                |> String.slice(0, @search_text_scan_limit)

              query = derive_search_query(search_text)
              focus_query = derive_focus_query(search_text, query)

              # Run grep operation for the derived query
              grep_res =
                if tool_allowed?("grep_search", allowed_tools) do
                  OperationManager.run_sync_operation(
                    session_id,
                    parent_op_id,
                    "ExplorerAgent",
                    "grep_search",
                    "Explorer: Grepping for modules and definitions",
                    %{query: query},
                    fn p ->
                      Tools.execute("grep_search", %{"query" => query}, project_root, p)
                    end,
                    Keyword.get(opts, :inner_timeout, @inner_timeout)
                  )
                else
                  {:error, {:tool_not_allowed, "grep_search"}}
                end

              cond do
                cancelled_fun(state).() ->
                  {:error, :cancelled}

                true ->
                  progress.(45, "Generating structural repository map...")

                  repo_map_res =
                    if tool_allowed?("repo_map", allowed_tools) do
                      RepoMap.generate(project_root,
                        focus_query: focus_query,
                        max_bytes: @repo_map_max_bytes
                      )
                    else
                      {:error, {:tool_not_allowed, "repo_map"}}
                    end

                  if cancelled_fun(state).() do
                    {:error, :cancelled}
                  else
                    progress.(65, "Scanning AST symbols and references...")

                    ast_symbols =
                      if tool_allowed?("ast_search", allowed_tools) do
                        case ASTSearch.search(project_root, %{type: "module"}) do
                          {:ok, syms} -> syms
                          _ -> []
                        end
                      else
                        []
                      end

                    symbol_refs =
                      if tool_allowed?("find_references", allowed_tools) or
                           tool_allowed?("ast_search", allowed_tools) do
                        search_text
                        |> extract_candidate_symbols(ast_symbols)
                        |> query_symbol_references(project_root)
                      else
                        []
                      end

                    if cancelled_fun(state).() do
                      {:error, :cancelled}
                    else
                      progress.(80, "Synthesizing codebase context...")

                      semantic_hits =
                        if tool_allowed?("semantic_code_search", allowed_tools) do
                          query_lexical_semantic_index(
                            project_root,
                            focus_query,
                            query,
                            opts,
                            state
                          )
                        else
                          []
                        end

                      context_summary =
                        synthesize_context_summary(
                          project_root,
                          grep_res,
                          ast_symbols,
                          symbol_refs,
                          semantic_hits,
                          repo_map_res
                        )

                      progress.(100, "Exploration complete")
                      {:ok, context_summary}
                    end
                  end
              end
            end
          end,
          Keyword.get(opts, :inner_timeout, @inner_timeout)
        )
      end)

    case explore_res do
      {:ok, summary} ->
        new_state = %State{
          state
          | status: :idle,
            last_result: summary,
            history: Enum.take([summary | state.history], @history_limit)
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
  def handle_call({:run_command, command, opts}, _from, %State{} = state) do
    project_root = opts[:project_root] || state.project_root
    timeout = Keyword.get(opts, :timeout_ms, 30_000)

    args = %{
      "command" => command,
      "project_id" => trusted_project_id(state),
      "run_id" => opts[:run_id],
      "session_id" => state.session_id,
      "agent_name" => "ExplorerAgent",
      "op_id" => opts[:op_id] || state.current_op_id,
      "timeout_ms" => timeout
    }

    res =
      with_workspace_delegation(opts[:workspace_lock_delegation], fn ->
        Tools.execute("run_command", args, project_root, fn _, _ -> :ok end)
      end)

    {:reply, res, state}
  end

  @impl true
  def handle_call(:get_state, _from, %State{} = state) do
    {:reply, state, state}
  end

  defp trusted_project_id(state) do
    (state.session && state.session.project_id) ||
      case IexCode.Sessions.get_session(state.session_id) do
        %{project_id: project_id} -> project_id
        _ -> nil
      end
  end

  defp with_workspace_delegation(nil, fun), do: fun.()

  defp with_workspace_delegation(delegation, fun) do
    IexCode.WorkspaceLocks.with_delegation(delegation, fun)
  end

  # Search derivation & context synthesis

  defp derive_search_query(text) do
    words =
      text
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_\-]+/, " ")
      |> String.split(" ", trim: true)
      |> Enum.reject(&(String.length(&1) < 4 or &1 in @stopwords))
      |> Enum.uniq()
      |> Enum.take(3)

    case words do
      [] -> "defmodule"
      words -> Enum.map_join(words, "|", &Regex.escape/1)
    end
  end

  defp derive_focus_query(text, grep_query) do
    words =
      text
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_\-.\/]+/, " ")
      |> String.split(" ", trim: true)
      |> Enum.reject(&(String.length(&1) < 3 or &1 in @stopwords))
      |> Enum.uniq()
      |> Enum.take(5)

    cond do
      words != [] -> Enum.join(words, " ")
      grep_query != "defmodule" -> String.replace(grep_query, "|", " ")
      true -> grep_query
    end
  end

  defp extract_candidate_symbols(search_text, ast_symbols) when is_binary(search_text) do
    qualified_calls =
      Regex.scan(
        ~r/\b([A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\.[a-z_][a-zA-Z0-9_?!]*(?:\/\d+)?)\b/,
        search_text,
        capture: :all_but_first
      )
      |> List.flatten()

    dotted_modules =
      Regex.scan(
        ~r/\b([A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]+)+)\b/,
        search_text,
        capture: :all_but_first
      )
      |> List.flatten()

    camel_modules =
      Regex.scan(
        ~r/\b([A-Z][a-z0-9]+(?:[A-Z][A-Za-z0-9_]*)+)\b/,
        search_text,
        capture: :all_but_first
      )
      |> List.flatten()
      |> Enum.reject(&MapSet.member?(@prompt_verbs, &1))

    unqualified_fun_arities =
      Regex.scan(
        ~r/(?<![A-Za-z0-9_.])([a-z_][a-zA-Z0-9_?!]*\/\d+)\b/,
        search_text,
        capture: :all_but_first
      )
      |> List.flatten()

    down_text = String.downcase(search_text)

    ast_matched_modules =
      ast_symbols
      |> Enum.map(&Map.get(&1, :name))
      |> Enum.filter(&is_binary/1)
      |> Enum.filter(fn mod_name ->
        short = mod_name |> String.split(".") |> List.last() |> String.downcase()

        String.length(short) >= 3 and
          (String.contains?(down_text, String.downcase(mod_name)) or
             Regex.match?(~r/\b#{Regex.escape(short)}\b/, down_text))
      end)

    single_cap_modules =
      Regex.scan(~r/\b([A-Z][a-zA-Z0-9_]{2,})\b/, search_text, capture: :all_but_first)
      |> List.flatten()
      |> Enum.reject(&MapSet.member?(@prompt_verbs, &1))

    base_modules =
      (dotted_modules ++ camel_modules ++ ast_matched_modules ++ single_cap_modules)
      |> Enum.uniq()

    qualified_from_ast =
      for mod <- Enum.take(base_modules, 2),
          fun_arity <- Enum.take(unqualified_fun_arities, 2) do
        "#{mod}.#{fun_arity}"
      end

    (qualified_calls ++
       qualified_from_ast ++
       dotted_modules ++
       camel_modules ++
       ast_matched_modules ++
       single_cap_modules)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(@max_symbol_candidates)
  end

  defp query_symbol_references([], _project_root), do: []

  defp query_symbol_references(candidates, project_root) when is_list(candidates) do
    candidates
    |> Enum.flat_map(fn symbol ->
      case SymbolRefactor.find_references(project_root, symbol, limit: 5) do
        {:ok, [_ | _] = refs} ->
          Enum.map(refs, &Map.put(&1, :symbol, symbol))

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(&{&1.file, &1.line, &1.column, &1.kind})
    |> Enum.take(8)
  rescue
    _ -> []
  end

  defp query_lexical_semantic_index(project_root, focus_query, grep_query, opts, state) do
    candidate_keys =
      [opts[:project_id], safe_trusted_project_id(state), project_root, Path.expand(project_root)]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    case Enum.find(candidate_keys, &has_indexed_chunks?/1) do
      nil ->
        []

      key ->
        lexical_query =
          if is_binary(focus_query) and focus_query != "" and focus_query != "defmodule",
            do: focus_query,
            else: String.replace(grep_query, "|", " ")

        case Indexer.search(key, lexical_query, mode: :lexical, limit: 5, threshold: 0.05) do
          {:ok, results} when is_list(results) -> results
          _ -> []
        end
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp safe_trusted_project_id(state) do
    trusted_project_id(state)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp has_indexed_chunks?(project_key) when is_binary(project_key) do
    table = Indexer.table_name()

    ets_count =
      if :ets.whereis(table) != :undefined do
        :ets.select_count(table, [
          {{:_, project_key, :_, :_, :_, :_, :_, :_, :_}, [], [true]}
        ])
      else
        0
      end

    if ets_count > 0 do
      true
    else
      case Indexer.stats(project_key) do
        %{ets_chunks: n} when is_integer(n) and n > 0 ->
          true

        %{db_chunks: n} when is_integer(n) and n > 0 ->
          match?(
            {:ok, warmed} when is_integer(warmed) and warmed > 0,
            Indexer.warm_cache(project_key)
          )

        _ ->
          false
      end
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp synthesize_context_summary(
         project_root,
         grep_res,
         ast_symbols,
         symbol_refs,
         semantic_hits,
         repo_map_res
       ) do
    grep_output =
      case grep_res do
        {:ok, output} when is_binary(output) and byte_size(output) > 0 -> output
        _ -> nil
      end

    grep_has_matches? = is_binary(grep_output) and not no_grep_matches?(grep_output)

    ast_section =
      if ast_symbols != [] do
        sym_list =
          ast_symbols
          |> Enum.take(10)
          |> Enum.map_join("\n", fn sym ->
            "- #{sym.name} (#{Path.relative_to(sym.file, project_root)}:#{sym.line})"
          end)
          |> clamp_utf8_bytes(450)

        "Discovered AST modules:\n#{sym_list}"
      end

    refs_section =
      if symbol_refs != [] do
        ref_lines =
          symbol_refs
          |> Enum.map_join("\n", fn ref ->
            "- #{ref.symbol} -> #{ref.file}:#{ref.line}:#{ref.column} [#{ref.kind}] #{ref.snippet}"
          end)
          |> clamp_utf8_bytes(650)

        "Symbol references:\n#{ref_lines}"
      end

    semantic_section =
      if semantic_hits != [] do
        hit_lines =
          semantic_hits
          |> Enum.take(5)
          |> Enum.map_join("\n", fn hit ->
            sym = hit.symbol_name || hit.chunk_type || "chunk"

            preview =
              hit.content |> String.replace(~r/\s+/, " ") |> String.trim() |> clamp_utf8_bytes(90)

            "- #{hit.file_path}:#{hit.start_line}-#{hit.end_line} (#{sym}, score=#{hit.score}): #{preview}"
          end)
          |> clamp_utf8_bytes(650)

        "Lexical semantic matches:\n#{hit_lines}"
      end

    repo_map_raw =
      case repo_map_res do
        {:ok, map_text}
        when is_binary(map_text) and byte_size(map_text) > 0 ->
          if String.starts_with?(map_text, "No supported source files found") do
            nil
          else
            map_text
          end

        _ ->
          nil
      end

    non_grep_sections =
      [ast_section, refs_section, semantic_section]
      |> Enum.reject(&is_nil/1)

    grep_section =
      cond do
        grep_has_matches? ->
          "Found key modules in workspace:\n#{clamp_utf8_bytes(grep_output, 1_000)}"

        is_binary(grep_output) and non_grep_sections == [] and is_nil(repo_map_raw) ->
          "Found key modules in workspace:\n#{clamp_utf8_bytes(grep_output, 1_000)}"

        true ->
          nil
      end

    prior_sections =
      [grep_section | non_grep_sections]
      |> Enum.reject(&is_nil/1)

    prior_bytes =
      prior_sections
      |> Enum.join("\n\n")
      |> byte_size()

    repo_map_section =
      if is_binary(repo_map_raw) do
        heading = "Structural repository map:\n"
        sep_bytes = if prior_sections == [], do: 0, else: 2
        remaining = @max_context_summary_bytes - prior_bytes - sep_bytes - byte_size(heading)

        if remaining >= 120 do
          heading <> clamp_utf8_bytes(repo_map_raw, min(@repo_map_max_bytes, remaining))
        end
      end

    sections =
      (prior_sections ++ [repo_map_section])
      |> Enum.reject(&is_nil/1)

    case sections do
      [] ->
        "Workspace exploration complete. Ready for implementation."

      _ ->
        sections
        |> Enum.join("\n\n")
        |> clamp_utf8_bytes(@max_context_summary_bytes)
    end
  end

  defp no_grep_matches?(output) when is_binary(output) do
    String.contains?(output, "No matches found for ") or
      String.contains?(output, "No matches in the scanned portion.")
  end

  defp clamp_utf8_bytes(text, max_bytes)
       when is_binary(text) and is_integer(max_bytes) and max_bytes >= 0 do
    if byte_size(text) <= max_bytes do
      text
    else
      do_clamp_utf8(binary_part(text, 0, max_bytes))
    end
  end

  defp do_clamp_utf8(<<>>), do: ""

  defp do_clamp_utf8(bin) do
    if String.valid?(bin) do
      bin
    else
      do_clamp_utf8(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end

  defp tool_allowed?(_tool_name, :all), do: true
  defp tool_allowed?(_tool_name, nil), do: true

  defp tool_allowed?(tool_name, allowed_tools) when is_list(allowed_tools),
    do: tool_name in Enum.map(allowed_tools, &to_string/1)

  defp tool_allowed?(_tool_name, _allowed_tools), do: false

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

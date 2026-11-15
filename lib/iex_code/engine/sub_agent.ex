defmodule IexCode.Engine.SubAgent do
  @moduledoc """
  Runs a bounded child agent loop on behalf of a parent run (`spawn_agent`).

  The child gets its own run row (delegating the parent lease), its own
  command history, and a capped turn budget. Spawn depth is capped so a
  confused model cannot fork recursively.

  Supports execution modes (`"coder"` default, plus `"research"` / `"read_only"`
  which restrict `allowed_tools` to non-mutating inspection/search tools) and
  optional Git worktree isolation (`isolate_worktree: true`).
  """

  alias IexCode.Engine.{AgentLoop, PlanStore}
  alias IexCode.{Projects, Runs, Sessions, WorkspacePath}
  alias IexCode.Runs.Run

  @max_depth 2
  @max_child_turns 10
  @default_child_turns 5
  @max_summary_chars 20_000
  @max_error_chars 4_000
  @max_diff_stat_chars 8_000
  @max_changed_files 500

  @valid_modes ~w(coder research read_only)

  @read_only_tools ~w(
    read_file
    list_dir
    grep_search
    ast_search
    find_references
    semantic_code_search
    repo_map
    diagnostics
    git_status
    git_diff
    web_search
    fetch_url
  )

  @autonomy_passthrough_tools ~w(update_plan request_input spawn_agent)

  @type mode :: String.t() | :coder | :research | :read_only

  @type context :: %{
          required(:llm) => module(),
          required(:tool_executor) => module(),
          required(:lease_owner) => String.t(),
          required(:run_attempt) => pos_integer(),
          required(:run_lease_generation) => pos_integer(),
          optional(:max_turns) => pos_integer() | nil,
          optional(:mode) => mode() | nil,
          optional(:isolate_worktree) => boolean() | nil
        }

  @doc """
  Returns the read-only inspection and search tool allowlist used for
  `"research"` and `"read_only"` sub-agent modes.
  """
  @spec read_only_tools() :: [String.t()]
  def read_only_tools, do: @read_only_tools

  @doc """
  Spawns a child run for `objective` under `parent_run_id`.

  `context` carries the loop adapters, lease delegated by the parent agent loop,
  and optional `:max_turns`, `:mode` (`"coder"` | `"research"` | `"read_only"`),
  and `:isolate_worktree` (`boolean()`). Returns `{:ok, summary}` with the child
  outcome (including `"summary"` and `"message_id"`, plus `"changed_files"` and
  `"diff_stat"` when `isolate_worktree: true`).
  """
  @spec run(
          String.t(),
          String.t(),
          String.t(),
          context(),
          (non_neg_integer(), String.t() -> any()) | keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def run(parent_run_id, objective, project_root, context, progress \\ fn _p, _m -> :ok end)

  def run(parent_run_id, objective, project_root, context, opts)
      when is_binary(parent_run_id) and is_binary(objective) and is_binary(project_root) and
             is_map(context) and is_list(opts) do
    if Keyword.keyword?(opts) do
      run(parent_run_id, objective, project_root, merge_opts(context, opts), fn _p, _m -> :ok end)
    else
      {:error, :invalid_sub_agent}
    end
  end

  def run(parent_run_id, objective, project_root, context, progress)
      when is_binary(parent_run_id) and is_binary(objective) and is_binary(project_root) and
             is_map(context) and is_function(progress, 2) do
    max_turns = child_turns(context_value(context, :max_turns))

    with {:ok, mode} <- normalize_mode(context_value(context, :mode)),
         {:ok, isolate_worktree?} <-
           normalize_isolate_worktree(context_value(context, :isolate_worktree)),
         {:ok, parent} <- fetch_parent(parent_run_id),
         {:ok, depth} <- spawn_depth(parent),
         :ok <- validate_context(context),
         {:ok, allowed_tools} <- resolve_child_allowed_tools(parent, mode),
         {:ok, child} <-
           create_child(
             parent,
             objective,
             depth,
             max_turns,
             mode,
             allowed_tools,
             isolate_worktree?,
             context
           ) do
      run_child_lifecycle(
        child,
        project_root,
        context,
        progress,
        depth,
        max_turns,
        mode,
        allowed_tools,
        isolate_worktree?
      )
    end
  end

  def run(_parent_run_id, _objective, _project_root, _context, _progress),
    do: {:error, :invalid_sub_agent}

  @spec run(
          String.t(),
          String.t(),
          String.t(),
          context(),
          (non_neg_integer(), String.t() -> any()),
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def run(parent_run_id, objective, project_root, context, progress, opts)
      when is_binary(parent_run_id) and is_binary(objective) and is_binary(project_root) and
             is_map(context) and is_function(progress, 2) and is_list(opts) do
    if Keyword.keyword?(opts) do
      run(parent_run_id, objective, project_root, merge_opts(context, opts), progress)
    else
      {:error, :invalid_sub_agent}
    end
  end

  def run(_parent_run_id, _objective, _project_root, _context, _progress, _opts),
    do: {:error, :invalid_sub_agent}

  @doc false
  def execute(tool_name, args, root_path, on_progress \\ fn _p, _m -> :ok end)
      when is_map(args) and is_binary(root_path) and is_function(on_progress, 2) do
    case lookup_isolated_frame(root_path) do
      {:ok, %{executor: IexCode.Tools, temp_project_id: temp_project_id}} ->
        routed_args = route_isolated_tool_args(tool_name, args, temp_project_id)
        IexCode.Tools.execute(tool_name, routed_args, root_path, on_progress)

      {:ok, %{executor: executor}} ->
        executor.execute(tool_name, args, root_path, on_progress)

      :error ->
        IexCode.Tools.execute(tool_name, args, root_path, on_progress)
    end
  end

  defp run_child_lifecycle(
         child,
         project_root,
         context,
         progress,
         depth,
         max_turns,
         mode,
         allowed_tools,
         isolate_worktree?
       ) do
    execution =
      try do
        if isolate_worktree? do
          execute_isolated(child, project_root, context, progress, allowed_tools)
        else
          case execute_loop(
                 child,
                 project_root,
                 context,
                 progress,
                 allowed_tools,
                 context.tool_executor
               ) do
            {:ok, outcome} -> {:ok, outcome, nil}
            other -> other
          end
        end
      rescue
        error -> {:error, {error, __STACKTRACE__}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case execution do
      {:ok, outcome, worktree_diff} ->
        with {:ok, _completed} <- finalize_child_completed(child, context) do
          {:ok, build_result_map(child, depth, max_turns, mode, outcome, worktree_diff)}
        end

      {:paused, _paused} ->
        PlanStore.clear(child.id)
        _ = finalize_child_failed(child, :sub_agent_cannot_pause, context)
        {:error, :sub_agent_cannot_pause}

      {:error, reason} ->
        _ = finalize_child_failed(child, reason, context)
        {:error, reason}
    end
  end

  defp execute_loop(child, root_path, context, progress, allowed_tools, tool_executor) do
    AgentLoop.execute(child, root_path, progress,
      llm: context.llm,
      tool_executor: tool_executor,
      allowed_tools: allowed_tools,
      run_lease_owner: context.lease_owner,
      run_attempt: context.run_attempt,
      run_lease_generation: context.run_lease_generation
    )
  end

  defp execute_isolated(child, project_root, context, progress, allowed_tools) do
    with :ok <- ensure_directory(project_root),
         {:ok, base_sha} <- resolve_git_head(project_root) do
      worktree_path = allocate_worktree_path(child.id)
      real_executor = unwrap_executor(context.tool_executor)

      try do
        with :ok <- create_git_worktree(project_root, worktree_path),
             {:ok, temp_project} <-
               maybe_register_temp_project(real_executor, child.id, worktree_path) do
          try do
            temp_project_id = if temp_project, do: temp_project.id

            loop_result =
              with_isolated_frame(real_executor, worktree_path, temp_project_id, fn ->
                execute_loop(child, worktree_path, context, progress, allowed_tools, __MODULE__)
              end)

            case loop_result do
              {:ok, outcome} ->
                diff = collect_worktree_changes(worktree_path, base_sha)
                {:ok, outcome, diff}

              other ->
                other
            end
          after
            cleanup_temp_project(temp_project)
          end
        end
      after
        cleanup_git_worktree(project_root, worktree_path)
      end
    end
  end

  defp finalize_child_completed(child, context) do
    Runs.finalize_run_worker(child, "completed", %{}, authority_opts(context))
  end

  defp finalize_child_failed(child, reason, context) do
    summary = format_error_summary(reason)

    Runs.finalize_run_worker(
      child,
      "failed",
      %{
        error_message: summary,
        error_details: %{"reason" => summary}
      },
      authority_opts(context)
    )
  end

  defp authority_opts(context) do
    [
      lease_owner: context.lease_owner,
      run_attempt: context.run_attempt,
      lease_generation: context.run_lease_generation
    ]
  end

  defp build_result_map(child, depth, max_turns, mode, outcome, worktree_diff) do
    base = %{
      "child_run_id" => child.id,
      "depth" => depth + 1,
      "max_turns" => max_turns,
      "mode" => mode,
      "turns" => Map.get(outcome, :turns, Map.get(outcome, "turns")),
      "tool_calls" => Map.get(outcome, :tool_calls, Map.get(outcome, "tool_calls")),
      "usage" => Map.get(outcome, :usage, Map.get(outcome, "usage")),
      "summary" => extract_summary(outcome),
      "message_id" => Map.get(outcome, :message_id, Map.get(outcome, "message_id"))
    }

    case worktree_diff do
      %{changed_files: changed_files, diff_stat: diff_stat} ->
        Map.merge(base, %{
          "changed_files" => changed_files,
          "diff_stat" => diff_stat
        })

      nil ->
        base
    end
  end

  defp extract_summary(outcome) when is_map(outcome) do
    raw =
      Map.get(outcome, :content) ||
        Map.get(outcome, "content") ||
        Map.get(outcome, :summary) ||
        Map.get(outcome, "summary") ||
        ""

    bounded_text(raw, @max_summary_chars)
  end

  defp extract_summary(_outcome), do: ""

  defp format_error_summary(reason) when is_binary(reason) do
    case bounded_text(reason, @max_error_chars) do
      "" -> "Sub-agent execution failed"
      text -> text
    end
  end

  defp format_error_summary({exception, stacktrace})
       when is_exception(exception) and is_list(stacktrace) do
    Exception.format(:error, exception, stacktrace)
    |> bounded_text(@max_error_chars)
    |> non_empty_error()
  end

  defp format_error_summary(exception) when is_exception(exception) do
    exception
    |> Exception.message()
    |> bounded_text(@max_error_chars)
    |> non_empty_error()
  end

  defp format_error_summary(reason) do
    reason
    |> inspect(limit: 20, printable_limit: @max_error_chars)
    |> bounded_text(@max_error_chars)
    |> non_empty_error()
  end

  defp non_empty_error(""), do: "Sub-agent execution failed"
  defp non_empty_error(text), do: text

  defp bounded_text(nil, _maximum), do: ""

  defp bounded_text(value, maximum) when is_binary(value) do
    value
    |> Sessions.sanitize_utf8()
    |> String.slice(0, maximum)
  end

  defp bounded_text(value, maximum) do
    value
    |> to_string()
    |> bounded_text(maximum)
  end

  defp ensure_directory(path) do
    if File.dir?(path), do: :ok, else: {:error, :invalid_project_root}
  end

  defp resolve_git_head(project_root) do
    case git_cmd(project_root, ["rev-parse", "--verify", "HEAD"]) do
      {:ok, sha} -> {:ok, String.trim(sha)}
      {:error, reason} -> {:error, {:worktree_unavailable, reason}}
    end
  end

  defp allocate_worktree_path(child_id) do
    tmp_base =
      case WorkspacePath.resolve(System.tmp_dir!(), "") do
        {:ok, canonical} -> canonical
        {:error, _reason} -> Path.expand(System.tmp_dir!())
      end

    suffix = System.unique_integer([:positive, :monotonic])
    Path.join(tmp_base, "iex-subagent-wt-#{child_id}-#{suffix}")
  end

  defp create_git_worktree(project_root, worktree_path) do
    case git_cmd(project_root, ["worktree", "add", "--detach", worktree_path, "HEAD"]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:worktree_add_failed, reason}}
    end
  end

  defp collect_worktree_changes(worktree_path, base_sha) do
    _ = git_cmd(worktree_path, ["add", "-N", "--", "."])

    changed_files =
      case git_cmd(worktree_path, ["diff", "--name-only", base_sha]) do
        {:ok, output} ->
          output
          |> String.split(~r/\r?\n/, trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()
          |> Enum.take(@max_changed_files)

        {:error, _reason} ->
          []
      end

    diff_stat =
      case git_cmd(worktree_path, ["diff", "--stat", base_sha]) do
        {:ok, output} ->
          output
          |> String.trim()
          |> bounded_text(@max_diff_stat_chars)

        {:error, _reason} ->
          ""
      end

    %{changed_files: changed_files, diff_stat: diff_stat}
  end

  defp cleanup_git_worktree(project_root, worktree_path) do
    _ = git_cmd(project_root, ["worktree", "remove", "--force", worktree_path])
    _ = File.rm_rf(worktree_path)
    _ = git_cmd(project_root, ["worktree", "prune"])
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp git_cmd(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _code} -> {:error, bounded_text(String.trim(output), 1_000)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp maybe_register_temp_project(IexCode.Tools, child_id, worktree_path) do
    case Projects.create_project(%{
           name: "subagent-worktree-#{String.slice(child_id, 0, 16)}",
           root_path: Path.expand(worktree_path)
         }) do
      {:ok, project} -> {:ok, project}
      {:error, reason} -> {:error, {:worktree_project_registration_failed, reason}}
    end
  end

  defp maybe_register_temp_project(_custom_executor, _child_id, _worktree_path), do: {:ok, nil}

  defp cleanup_temp_project(nil), do: :ok

  defp cleanup_temp_project(project) do
    _ = Projects.delete_project(project)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp with_isolated_frame(executor, worktree_path, temp_project_id, fun) do
    key = {__MODULE__, :isolated_stack}
    previous = Process.get(key, [])

    frame = %{
      executor: executor,
      worktree_path: canonical_dir(worktree_path),
      temp_project_id: temp_project_id
    }

    Process.put(key, [frame | previous])

    try do
      fun.()
    after
      case previous do
        [] -> Process.delete(key)
        stack -> Process.put(key, stack)
      end
    end
  end

  defp lookup_isolated_frame(root_path) do
    target = canonical_dir(root_path)
    stack = Process.get({__MODULE__, :isolated_stack}, [])

    case Enum.find(stack, &(&1.worktree_path == target)) || List.first(stack) do
      %{} = frame -> {:ok, frame}
      nil -> :error
    end
  end

  defp unwrap_executor(__MODULE__) do
    case Process.get({__MODULE__, :isolated_stack}, []) do
      [%{executor: executor} | _rest] -> executor
      [] -> IexCode.Tools
    end
  end

  defp unwrap_executor(executor), do: executor

  defp route_isolated_tool_args(tool_name, args, _temp_project_id)
       when tool_name in @autonomy_passthrough_tools do
    args
  end

  defp route_isolated_tool_args(_tool_name, args, temp_project_id) do
    cleaned = Map.drop(args, ["project_id", "session_id", :project_id, :session_id])

    if is_binary(temp_project_id) do
      Map.put(cleaned, "project_id", temp_project_id)
    else
      cleaned
    end
  end

  defp canonical_dir(path) do
    case WorkspacePath.resolve(path, "") do
      {:ok, resolved} -> resolved
      {:error, _reason} -> Path.expand(path)
    end
  end

  defp normalize_mode(nil), do: {:ok, "coder"}

  defp normalize_mode(mode) when is_atom(mode) do
    mode |> Atom.to_string() |> normalize_mode()
  end

  defp normalize_mode(mode) when is_binary(mode) do
    normalized = mode |> String.trim() |> String.downcase()
    if normalized in @valid_modes, do: {:ok, normalized}, else: {:error, :invalid_sub_agent_mode}
  end

  defp normalize_mode(_mode), do: {:error, :invalid_sub_agent_mode}

  defp normalize_isolate_worktree(nil), do: {:ok, false}
  defp normalize_isolate_worktree(flag) when is_boolean(flag), do: {:ok, flag}
  defp normalize_isolate_worktree(_flag), do: {:error, :invalid_isolate_worktree}

  defp resolve_child_allowed_tools(%Run{metadata: metadata}, mode) do
    parent_allowed = parent_allowed_tools(metadata)

    case {mode, parent_allowed} do
      {"coder", :all} ->
        {:ok, :all}

      {"coder", tools} when is_list(tools) ->
        {:ok, tools}

      {ro_mode, :all} when ro_mode in ["research", "read_only"] ->
        {:ok, @read_only_tools}

      {ro_mode, tools} when ro_mode in ["research", "read_only"] and is_list(tools) ->
        {:ok, Enum.filter(@read_only_tools, &(&1 in tools))}
    end
  end

  defp parent_allowed_tools(metadata) when is_map(metadata) do
    policy = Map.get(metadata, "execution_policy") || Map.get(metadata, :execution_policy) || %{}

    raw =
      (is_map(policy) && (Map.get(policy, "allowed_tools") || Map.get(policy, :allowed_tools))) ||
        Map.get(metadata, "allowed_tools") ||
        Map.get(metadata, :allowed_tools)

    case raw do
      value when value in [nil, :all, "all"] ->
        :all

      values when is_list(values) ->
        values |> Enum.map(&to_string/1) |> Enum.uniq()

      _other ->
        :all
    end
  end

  defp parent_allowed_tools(_metadata), do: :all

  defp fetch_parent(parent_run_id) do
    case Runs.get_run(parent_run_id) do
      %Run{} = run -> {:ok, run}
      _missing -> {:error, :parent_run_not_found}
    end
  end

  defp spawn_depth(%Run{metadata: %{"spawn_depth" => depth}}) when is_integer(depth) do
    if depth >= @max_depth, do: {:error, :max_spawn_depth_exceeded}, else: {:ok, depth}
  end

  defp spawn_depth(%Run{}), do: {:ok, 0}

  defp validate_context(%{
         llm: llm,
         tool_executor: tool_executor,
         lease_owner: lease_owner,
         run_attempt: run_attempt,
         run_lease_generation: run_lease_generation
       })
       when is_atom(llm) and is_atom(tool_executor) do
    cond do
      not adapter?(llm, :chat, 5) ->
        {:error, :invalid_sub_agent_llm}

      not adapter?(tool_executor, :execute, 4) ->
        {:error, :invalid_sub_agent_tools}

      not (is_binary(lease_owner) and lease_owner != "") ->
        {:error, :invalid_sub_agent_context}

      not (is_integer(run_attempt) and run_attempt >= 1) ->
        {:error, :invalid_sub_agent_context}

      not (is_integer(run_lease_generation) and run_lease_generation >= 1) ->
        {:error, :invalid_sub_agent_context}

      true ->
        :ok
    end
  end

  defp validate_context(_context), do: {:error, :invalid_sub_agent_context}

  defp adapter?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp child_lease_expiry(%{lease_expires_at: %DateTime{} = expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
      do: expires_at,
      else: DateTime.add(DateTime.utc_now(), 300, :second)
  end

  defp child_lease_expiry(_parent), do: DateTime.add(DateTime.utc_now(), 300, :second)

  defp create_child(
         parent,
         objective,
         depth,
         max_turns,
         mode,
         allowed_tools,
         isolate_worktree?,
         context
       ) do
    execution_policy =
      %{"agent_max_turns" => max_turns}
      |> maybe_put_allowed_tools(allowed_tools)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Runs.create_run(%{
      project_id: parent.project_id,
      session_id: parent.session_id,
      objective: objective,
      kind: "coding_agent",
      mode: "single",
      status: "running",
      started_at: now,
      heartbeat_at: now,
      lease_owner: context.lease_owner,
      attempt: context.run_attempt,
      max_attempts: max(context.run_attempt, 3),
      lease_generation: context.run_lease_generation,
      lease_expires_at: child_lease_expiry(parent),
      metadata: %{
        "sub_agent" => true,
        "sub_agent_mode" => mode,
        "isolate_worktree" => isolate_worktree?,
        "parent_run_id" => parent.id,
        "spawn_depth" => depth + 1,
        "execution_policy" => execution_policy
      }
    })
  end

  defp maybe_put_allowed_tools(policy, :all), do: policy

  defp maybe_put_allowed_tools(policy, tools) when is_list(tools),
    do: Map.put(policy, "allowed_tools", tools)

  defp merge_opts(context, opts) do
    Enum.reduce([:max_turns, :mode, :isolate_worktree], context, fn key, acc ->
      if Keyword.has_key?(opts, key), do: Map.put(acc, key, Keyword.get(opts, key)), else: acc
    end)
  end

  defp context_value(context, key) when is_map(context) and is_atom(key) do
    case Map.fetch(context, key) do
      {:ok, value} -> value
      :error -> Map.get(context, Atom.to_string(key))
    end
  end

  defp child_turns(nil), do: @default_child_turns
  defp child_turns(turns) when is_integer(turns) and turns > 0, do: min(turns, @max_child_turns)
  defp child_turns(_turns), do: @default_child_turns
end

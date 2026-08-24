defmodule IexCode.Engine.FleetManager do
  @moduledoc "Run-scoped owner and control router for a bounded durable agent fleet."
  use GenServer
  require Logger

  alias IexCode.Engine.{AgentRegistry, AgentSupervisor, FleetControlToken}
  alias IexCode.Runs
  alias IexCode.Runs.RunAgent

  @roles ~w(planner explorer coder verifier)a
  @lease_ms 30_000
  @heartbeat_ms 10_000

  def start_link(opts) do
    run = Keyword.fetch!(opts, :run)
    GenServer.start_link(__MODULE__, opts, name: AgentRegistry.via_fleet(run.id, :manager))
  end

  def activate(run_id, rows, opts \\ []) when is_list(rows) do
    GenServer.call(AgentRegistry.via_fleet(run_id, :manager), {:activate, rows, opts}, 30_000)
  end

  def list_agents(run_id), do: GenServer.call(AgentRegistry.via_fleet(run_id, :manager), :list)

  def agent_pid(run_id, agent_id) do
    GenServer.call(AgentRegistry.via_fleet(run_id, :manager), {:agent_pid, agent_id})
  end

  @doc "Returns the current live incarnation of one durable agent identity."
  def current_agent(run_id, agent_id) do
    GenServer.call(AgentRegistry.via_fleet(run_id, :manager), {:current_agent, agent_id})
  end

  def role_pids(run_id, role) when role in @roles do
    run_id
    |> list_agents()
    |> Enum.filter(&(&1.role == role and is_pid(&1.pid) and Process.alive?(&1.pid)))
    |> Enum.map(& &1.pid)
  end

  def drain_steering(run_id, agent_id) do
    GenServer.call(AgentRegistry.via_fleet(run_id, :manager), {:drain_steering, agent_id})
  end

  def control_all(run_id, action, payload \\ %{}) when action in [:pause, :resume] do
    GenServer.call(
      AgentRegistry.via_fleet(run_id, :manager),
      {:control_all, action, payload},
      30_000
    )
  end

  def apply_durable_control(run_id, control_id) do
    GenServer.call(
      AgentRegistry.via_fleet(run_id, :manager),
      {:apply_durable_control, control_id},
      30_000
    )
  end

  def runtime_begin(run_id, agent_id, generation, task) do
    GenServer.call(
      AgentRegistry.via_fleet(run_id, :manager),
      {:runtime_begin, agent_id, generation, task},
      30_000
    )
  end

  def runtime_progress(run_id, agent_id, generation, percent, message) do
    GenServer.call(
      AgentRegistry.via_fleet(run_id, :manager),
      {:runtime_progress, agent_id, generation, percent, message},
      30_000
    )
  end

  def runtime_finish(run_id, agent_id, generation, result) do
    GenServer.call(
      AgentRegistry.via_fleet(run_id, :manager),
      {:runtime_finish, agent_id, generation, result},
      30_000
    )
  end

  def runtime_usage(run_id, agent_id, generation, usage, source) do
    GenServer.call(
      AgentRegistry.via_fleet(run_id, :manager),
      {:runtime_usage, agent_id, generation, usage, source},
      30_000
    )
  end

  @doc false
  def control(run_id, agent_id, action, payload \\ %{})
      when action in [:pause, :resume, :cancel, :steer, :restart] do
    GenServer.call(
      AgentRegistry.via_fleet(run_id, :manager),
      {:control, agent_id, action, payload},
      30_000
    )
  end

  def stop(run_id, status \\ "interrupted") do
    GenServer.call(AgentRegistry.via_fleet(run_id, :manager), {:stop, status}, 30_000)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    run = Keyword.fetch!(opts, :run)
    lease_owner = Keyword.fetch!(opts, :fleet_lease_secret)
    Process.put(:fleet_lease_owner, lease_owner)

    Process.send_after(self(), :heartbeat, @heartbeat_ms)

    state = %{
      run: run,
      session: opts[:session],
      project_root: opts[:project_root],
      allowed_tools: Keyword.get(opts, :allowed_tools, :all),
      workspace_lock_delegation: opts[:workspace_lock_delegation],
      supervisor: AgentRegistry.via_fleet(run.id, :agent_supervisor),
      agents: %{},
      budget_callers: %{},
      activation_opts: opts
    }

    {:ok, state, {:continue, :rehydrate}}
  end

  @impl true
  def handle_continue(:rehydrate, state) do
    rows = Runs.list_run_agents(state.run.id)

    agents =
      Enum.reduce(rows, state.agents, fn row, agents ->
        case ensure_agent(state, agents, row, state.activation_opts) do
          {:ok, _entry, updated} -> updated
          {:error, _reason} -> agents
        end
      end)

    state = %{state | agents: agents}
    send(self(), :replay_controls)
    {:noreply, state}
  end

  @impl true
  def handle_call({:activate, rows, opts}, _from, state) do
    case validate_rows(state.run.id, rows) do
      :ok ->
        {agents, result} =
          Enum.reduce_while(rows, {state.agents, []}, fn row, {agents, result} ->
            case ensure_agent(state, agents, row, opts) do
              {:ok, entry, updated} -> {:cont, {updated, [public_entry(entry) | result]}}
              {:error, reason} -> {:halt, {agents, {:error, reason}}}
            end
          end)

        case result do
          {:error, _} = error -> {:reply, error, %{state | agents: agents}}
          entries -> {:reply, {:ok, Enum.reverse(entries)}, %{state | agents: agents}}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:list, _from, state) do
    entries =
      state.agents
      |> Map.values()
      |> Enum.sort_by(&{&1.position, &1.key})
      |> Enum.map(&public_entry/1)

    {:reply, entries, state}
  end

  def handle_call({:agent_pid, agent_id}, _from, state) do
    reply =
      case Map.get(state.agents, agent_id) do
        nil -> nil
        entry -> entry.pid
      end

    {:reply, reply, state}
  end

  def handle_call({:current_agent, agent_id}, _from, state) do
    {reply, state} =
      case Map.get(state.agents, agent_id) do
        %{pid: pid} = entry when is_pid(pid) ->
          with true <- Process.alive?(pid),
               %RunAgent{lease_generation: generation, status: status} = row <-
                 Runs.get_run_agent(state.run.id, agent_id),
               true <- generation == entry.generation,
               true <- status in RunAgent.leased_statuses(),
               {:ok, row} <- Runs.assert_run_agent_lease(row, lease_owner(), generation) do
            refreshed = %{entry | row: row, status: String.to_existing_atom(status)}
            {{:ok, public_entry(refreshed)}, put_in(state.agents[agent_id], refreshed)}
          else
            _ -> {{:error, :agent_not_active}, state}
          end

        nil ->
          {{:error, :agent_not_found}, state}

        _entry ->
          {{:error, :agent_not_active}, state}
      end

    {:reply, reply, state}
  end

  def handle_call({:drain_steering, agent_id}, _from, state) do
    case Map.get(state.agents, agent_id) do
      nil ->
        {:reply, [], state}

      entry ->
        case Runs.consume_run_agent_steering_controls(
               entry.row,
               lease_owner(),
               entry.generation
             ) do
          {:ok, directives} -> {:reply, Enum.map(directives, & &1["guidance"]), state}
          {:error, _reason} -> {:reply, [], state}
        end
    end
  end

  def handle_call({:control, agent_id, action, payload}, _from, state) do
    case Map.fetch(state.agents, agent_id) do
      :error ->
        {:reply, {:error, :agent_not_found}, state}

      {:ok, entry} ->
        case Runs.get_run_agent(entry.agent_id) do
          %RunAgent{lease_generation: generation} = row when generation == entry.generation ->
            fresh = %{entry | row: row, status: String.to_existing_atom(row.status)}
            apply_control(put_in(state.agents[agent_id], fresh), fresh, action, payload)

          _ ->
            {:reply, {:error, :lease_lost}, state}
        end
    end
  end

  def handle_call({:control_all, action, payload}, _from, state) do
    {results, updated_state} =
      Enum.reduce(state.agents, {[], state}, fn {agent_id, entry}, {results, acc} ->
        fresh = Map.get(acc.agents, agent_id, entry)

        case apply_control_result(acc, fresh, action, payload) do
          {:ok, result, updated} -> {[{agent_id, result} | results], updated}
          {:error, reason, updated} -> {[{agent_id, {:error, reason}} | results], updated}
        end
      end)

    {:reply, {:ok, Enum.reverse(results)}, updated_state}
  end

  def handle_call({:apply_durable_control, control_id}, _from, state) do
    case Runs.get_run_agent_control(control_id) do
      %{run_id: run_id, run_agent_id: agent_id} = control when run_id == state.run.id ->
        case Map.get(state.agents, agent_id) do
          nil ->
            {:reply, {:error, :agent_not_active}, state}

          entry ->
            case Runs.get_run_agent(state.run.id, agent_id) do
              %RunAgent{} = row ->
                fresh = %{
                  entry
                  | row: row,
                    generation: row.lease_generation,
                    status: String.to_existing_atom(row.status)
                }

                apply_control_queue(put_in(state.agents[agent_id], fresh), fresh, control)

              nil ->
                {:reply, {:error, :agent_not_found}, state}
            end
        end

      nil ->
        {:reply, {:error, :control_not_found}, state}

      _foreign ->
        {:reply, {:error, :agent_scope_mismatch}, state}
    end
  end

  def handle_call({:runtime_begin, agent_id, generation, task}, _from, state) do
    with {:ok, state} <- require_parent_run_status(state, ["running"]),
         {:ok, entry} <- runtime_entry(state, agent_id, generation),
         true <- entry.row.status == "idle" || {:error, :agent_not_available},
         {:ok, row} <-
           Runs.transition_run_agent(entry.row, "running", %{current_task: task, progress: 0},
             lease_owner: lease_owner(),
             lease_generation: generation
           ) do
      updated = %{entry | row: row, status: :running}
      {:reply, :ok, put_in(state.agents[agent_id], updated)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:runtime_progress, agent_id, generation, percent, message}, _from, state) do
    with {:ok, state} <- require_parent_run_status(state, ["running", "paused"]),
         {:ok, entry} <- runtime_entry(state, agent_id, generation),
         {:ok, row} <-
           Runs.heartbeat_run_agent(entry.row, lease_owner(), generation, @lease_ms, %{
             progress: min(max(percent, 0), 100),
             current_task: String.slice(message, 0, 20_000)
           }) do
      {:reply, :ok, put_in(state.agents[agent_id], %{entry | row: row})}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:runtime_finish, agent_id, generation, result}, _from, state) do
    with {:ok, state} <- require_parent_run_status(state, ["running", "paused"]),
         {:ok, entry} <- runtime_entry(state, agent_id, generation) do
      if entry.row.status == "running" do
        status = if entry.row.desired_state == "paused", do: "paused", else: "idle"

        attrs = %{
          current_task: nil,
          progress: if(match?({:ok, _}, result), do: 100, else: entry.row.progress),
          error_message: runtime_error(result)
        }

        case Runs.transition_run_agent(entry.row, status, attrs,
               lease_owner: lease_owner(),
               lease_generation: generation
             ) do
          {:ok, row} ->
            updated = %{entry | row: row, status: String.to_existing_atom(status)}
            {:reply, :ok, put_in(state.agents[agent_id], updated)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
      else
        {:reply, :ok, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:runtime_usage, agent_id, generation, usage, source},
        {caller_pid, _tag},
        state
      ) do
    with {:ok, state} <- require_parent_run_status(state, ["running", "paused"]),
         {:ok, entry} <- runtime_entry(state, agent_id, generation),
         {:ok, row} <-
           Runs.record_run_agent_usage(entry.row, usage, source,
             lease_owner: lease_owner(),
             lease_generation: generation
           ) do
      {:reply, :ok, put_in(state.agents[agent_id], %{entry | row: row})}
    else
      {:error, {:token_budget_exhausted, failed_run}} ->
        terminalize_budget_exhausted_fleet(
          state,
          failed_run,
          :token_budget_exhausted,
          caller_pid
        )

      {:error, {:cost_budget_exhausted, failed_run}} ->
        terminalize_budget_exhausted_fleet(
          state,
          failed_run,
          :cost_budget_exhausted,
          caller_pid
        )

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop, status}, _from, state)
      when status in ["completed", "failed", "cancelled", "interrupted"] do
    agents =
      Enum.reduce(state.agents, state.agents, fn {_id, entry}, agents ->
        FleetControlToken.cancel(entry.token)
        demonitor_entry(entry)
        _ = AgentSupervisor.stop_run_agent(state.supervisor, state.run.id, entry.agent_id)
        _ = release(entry, state, status, %{error_message: terminal_error(status)})
        Map.delete(agents, entry.agent_id)
      end)

    {:reply, :ok, %{state | agents: agents}}
  end

  defp terminal_error("completed"), do: nil
  defp terminal_error(status), do: "Run fleet #{status}"

  @impl true
  def handle_info(:heartbeat, state) do
    agents =
      Map.new(state.agents, fn {id, entry} ->
        updated =
          case Runs.heartbeat_run_agent(
                 entry.row,
                 lease_owner(),
                 entry.generation,
                 @lease_ms,
                 %{}
               ) do
            {:ok, row} ->
              %{entry | row: row}

            {:error, reason} ->
              FleetControlToken.cancel(entry.token)
              demonitor_entry(entry)
              _ = AgentSupervisor.stop_run_agent(state.supervisor, state.run.id, entry.agent_id)
              %{entry | pid: nil, ref: nil, status: :interrupted, error: inspect(reason)}
          end

        {id, updated}
      end)

    Process.send_after(self(), :heartbeat, @heartbeat_ms)
    send(self(), :replay_controls)
    {:noreply, %{state | agents: agents}}
  end

  def handle_info(:replay_controls, state) do
    {:noreply, replay_controls(state, 64)}
  end

  def handle_info({:terminate_budget_children, entries}, state) when is_list(entries) do
    Enum.each(entries, fn entry ->
      _ = AgentSupervisor.stop_run_agent(state.supervisor, state.run.id, entry.agent_id)
    end)

    {:noreply, state}
  end

  def handle_info({:terminate_budget_owner, ref}, state) when is_reference(ref) do
    case Map.pop(state.budget_callers, ref) do
      {nil, _callers} ->
        {:noreply, state}

      {entry, callers} ->
        Process.demonitor(ref, [:flush])
        _ = AgentSupervisor.stop_run_agent(state.supervisor, state.run.id, entry.agent_id)
        {:noreply, %{state | budget_callers: callers}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.budget_callers, ref) do
      {entry, callers} when not is_nil(entry) ->
        # The usage caller has now received the structured budget result and
        # completed its own unwind. Keep a bounded grace period so the owning
        # GenServer can relay the operation result to its caller before it is
        # terminated as well; the separate five-second timer remains the hard
        # fallback when a linked caller never exits.
        Process.send_after(self(), {:terminate_budget_children, [entry]}, 100)
        {:noreply, %{state | budget_callers: callers}}

      {nil, _callers} ->
        case Enum.find(state.agents, fn {_id, entry} -> entry.ref == ref end) do
          nil ->
            {:noreply, state}

          {agent_id, entry} ->
            FleetControlToken.cancel(entry.token)
            _ = AgentSupervisor.stop_run_agent(state.supervisor, state.run.id, entry.agent_id)
            _ = release(entry, state, "interrupted", %{error_message: inspect(reason)})
            updated = %{entry | pid: nil, ref: nil, status: :interrupted, error: inspect(reason)}
            {:noreply, put_in(state.agents[agent_id], updated)}
        end
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp replay_controls(state, 0), do: state

  defp replay_controls(state, remaining) do
    candidate =
      state.agents
      |> Enum.sort_by(fn {_id, entry} -> entry.position end)
      |> Enum.find_value(fn {_id, entry} ->
        control =
          entry.agent_id
          |> Runs.list_run_agent_controls()
          |> Enum.find(&(&1.status in ["pending", "claimed"]))

        cond do
          is_nil(control) -> nil
          control.kind == "restart" and control.status == "claimed" -> nil
          true -> {entry, control}
        end
      end)

    case candidate do
      nil ->
        state

      {entry, control} ->
        case apply_control_queue(state, entry, control) do
          {:reply, _result, updated} -> replay_controls(updated, remaining - 1)
        end
    end
  end

  defp ensure_agent(state, agents, %RunAgent{} = row, opts) do
    case Map.get(agents, row.id) do
      %{pid: pid} = entry when is_pid(pid) ->
        if Process.alive?(pid),
          do: {:ok, entry, agents},
          else: start_agent(state, agents, row, opts)

      _ ->
        start_agent(state, agents, row, opts)
    end
  end

  defp start_agent(state, agents, %RunAgent{} = row, opts) do
    with {:ok, claimed} <- claim_if_needed(row, lease_owner()) do
      start_claimed_agent(state, agents, claimed, opts)
    end
  end

  defp start_claimed_agent(state, agents, %RunAgent{} = claimed, opts) do
    with role when role in @roles <- normalize_role(claimed.role) do
      token = FleetControlToken.new()

      agent_opts =
        [
          session_id: state.run.session_id,
          session: state.session,
          project_root: state.project_root,
          generation: claimed.lease_generation,
          run_agent_id: claimed.id,
          control_token: token,
          allowed_tools: state.allowed_tools,
          workspace_lock_delegation: state.workspace_lock_delegation
        ] ++ opts

      case AgentSupervisor.start_run_agent(
             state.supervisor,
             state.run.id,
             claimed.id,
             role,
             agent_opts
           ) do
        {:ok, pid} ->
          with :ok <- validate_registration(state.run.id, claimed, role, pid),
               {:ok, ready} <- ready_agent_row(claimed, token) do
            entry = %{
              agent_id: claimed.id,
              key: claimed.key,
              role: role,
              position: claimed.position,
              generation: claimed.lease_generation,
              pid: pid,
              ref: Process.monitor(pid),
              token: token,
              row: ready,
              status: String.to_existing_atom(ready.status),
              error: nil
            }

            {:ok, entry, Map.put(agents, claimed.id, entry)}
          else
            {:error, reason} ->
              _ =
                AgentSupervisor.stop_run_agent(state.supervisor, state.run.id, claimed.id)

              _ =
                release_row(claimed, state, "interrupted", %{error_message: inspect(reason)})

              {:error, {claimed.key, reason}}
          end

        {:error, reason} ->
          _ = release_row(claimed, state, "interrupted", %{error_message: inspect(reason)})
          {:error, {claimed.key, reason}}
      end
    else
      nil -> {:error, {claimed.key, :invalid_role}}
    end
  end

  defp ready_agent_row(%RunAgent{status: "paused"} = claimed, token) do
    FleetControlToken.pause(token)
    {:ok, claimed}
  end

  defp ready_agent_row(%RunAgent{} = claimed, _token) do
    Runs.transition_run_agent(claimed, "idle", %{},
      lease_owner: lease_owner(),
      lease_generation: claimed.lease_generation
    )
  end

  defp claim_if_needed(%RunAgent{status: status} = row, owner)
       when status in ["pending", "interrupted"] do
    Runs.claim_run_agent(row, owner, @lease_ms)
  end

  defp claim_if_needed(%RunAgent{} = row, owner) do
    with {:ok, _asserted} <- Runs.assert_run_agent_lease(row, owner, row.lease_generation),
         {:ok, interrupted} <-
           Runs.release_run_agent_lease(
             row,
             owner,
             row.lease_generation,
             "interrupted",
             %{error_message: "fleet_manager_restarted"}
           ) do
      Runs.claim_run_agent(interrupted, owner, @lease_ms)
    end
  end

  defp apply_control(state, entry, :pause, _payload) do
    case transition_control_result(state, entry, "paused", %{desired_state: "paused"}) do
      {:ok, updated_state} ->
        FleetControlToken.pause(entry.token)
        {:reply, {:ok, :paused}, updated_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp apply_control(state, entry, :resume, _payload) do
    target = if entry.row.current_task, do: "running", else: "idle"

    case transition_control_result(state, entry, target, %{desired_state: "active"}) do
      {:ok, updated_state} ->
        FleetControlToken.resume(entry.token)
        {:reply, {:ok, :resumed}, updated_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp apply_control(state, _entry, :steer, payload) do
    guidance = value(payload, :guidance)

    if is_binary(guidance) and String.trim(guidance) != "" do
      {:reply, {:ok, :queued}, state}
    else
      {:reply, {:error, :invalid_guidance}, state}
    end
  end

  defp apply_control(state, entry, :cancel, _payload) do
    FleetControlToken.cancel(entry.token)
    demonitor_entry(entry)
    _ = AgentSupervisor.stop_run_agent(state.supervisor, state.run.id, entry.agent_id)

    case release(entry, state, "cancelled", %{desired_state: "stopped"}) do
      {:ok, row} ->
        updated = %{entry | pid: nil, ref: nil, status: :cancelled, row: row}
        {:reply, {:ok, :cancelled}, put_in(state.agents[entry.agent_id], updated)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp apply_control(state, entry, :restart, _payload) do
    FleetControlToken.cancel(entry.token)
    demonitor_entry(entry)
    _ = AgentSupervisor.stop_run_agent(state.supervisor, state.run.id, entry.agent_id)

    with {:ok, interrupted} <- release(entry, state, "interrupted", %{desired_state: "active"}),
         {:ok, restarted, agents} <-
           start_agent(state, Map.delete(state.agents, entry.agent_id), interrupted, []) do
      {:reply, {:ok, public_entry(restarted)}, %{state | agents: agents}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp apply_control_result(state, entry, action, payload) do
    case apply_control(state, entry, action, payload) do
      {:reply, {:ok, result}, updated} -> {:ok, result, updated}
      {:reply, {:error, reason}, updated} -> {:error, reason, updated}
    end
  end

  defp apply_control_queue(state, _entry, %{status: "applied"}),
    do: {:reply, {:ok, :already_applied}, state}

  defp apply_control_queue(state, entry, target) do
    if target.kind == "restart" and restart_control_at_head?(entry, target) do
      apply_restart_control(state, entry, target)
    else
      apply_regular_control_queue(state, entry, target)
    end
  end

  defp apply_regular_control_queue(state, entry, target) do
    case Runs.claim_next_run_agent_control(
           entry.row,
           lease_owner(),
           entry.generation
         ) do
      {:ok, claimed} ->
        action = String.to_existing_atom(claimed.kind)

        case apply_control_result(state, entry, action, claimed.payload) do
          {:ok, effect, updated_state} ->
            result = control_result(action, effect)

            case Runs.resolve_run_agent_control(
                   claimed,
                   "applied",
                   result,
                   lease_owner(),
                   claimed.claim_generation
                 ) do
              {:ok, _resolved} ->
                outward_effect = if action == :steer, do: :steered, else: effect

                if claimed.id == target.id do
                  {:reply, {:ok, outward_effect}, updated_state}
                else
                  next_entry = Map.get(updated_state.agents, entry.agent_id, entry)
                  apply_control_queue(updated_state, next_entry, target)
                end

              {:error, reason} ->
                {:reply, {:error, reason}, updated_state}
            end

          {:error, reason, updated_state} ->
            _ =
              Runs.resolve_run_agent_control(
                claimed,
                "rejected",
                %{"action" => Atom.to_string(action), "error" => error_code(reason)},
                lease_owner(),
                claimed.claim_generation
              )

            if claimed.id == target.id do
              {:reply, {:error, reason}, updated_state}
            else
              next_entry = Map.get(updated_state.agents, entry.agent_id, entry)
              apply_control_queue(updated_state, next_entry, target)
            end
        end

      :none ->
        {:reply, {:error, :control_not_claimable}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp restart_control_at_head?(entry, target) do
    active =
      entry.agent_id
      |> Runs.list_run_agent_controls()
      |> Enum.find(&(&1.status in ["pending", "claimed"]))

    case active do
      %{id: id} when id == target.id ->
        true

      _ ->
        false
    end
  end

  defp apply_restart_control(state, entry, _target) do
    FleetControlToken.cancel(entry.token)
    demonitor_entry(entry)
    _ = AgentSupervisor.stop_run_agent(state.supervisor, state.run.id, entry.agent_id)

    with {:ok, interrupted} <- prepare_restart_claim(entry, state),
         {:ok, {claimed_agent, claimed_control}} <-
           Runs.claim_restart_run_agent_control(interrupted, lease_owner(), @lease_ms),
         {:ok, restarted, agents} <-
           start_claimed_agent(
             state,
             Map.delete(state.agents, entry.agent_id),
             claimed_agent,
             []
           ),
         {:ok, _resolved} <-
           Runs.resolve_run_agent_control(
             claimed_control,
             "applied",
             control_result(:restart, public_entry(restarted)),
             lease_owner(),
             claimed_control.claim_generation
           ) do
      {:reply, {:ok, public_entry(restarted)}, %{state | agents: agents}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # An interrupted row has already surrendered its lease. Releasing it again is both
  # unnecessary and an invalid interrupted -> interrupted lifecycle transition. Live
  # incarnations must still be stopped and fenced into interrupted before the atomic
  # restart-control claim advances their generation.
  defp prepare_restart_claim(%{row: %RunAgent{status: "interrupted"}} = entry, _state) do
    {:ok, entry.row}
  end

  defp prepare_restart_claim(entry, state) do
    release(entry, state, "interrupted", %{desired_state: "active"})
  end

  defp control_result(:restart, %{generation: generation}) when is_integer(generation) do
    %{"action" => "restart", "status" => "restarted", "generation" => generation}
  end

  defp control_result(:steer, :queued),
    do: %{"action" => "steer", "status" => "queued"}

  defp control_result(action, status) when is_atom(status),
    do: %{"action" => Atom.to_string(action), "status" => Atom.to_string(status)}

  defp control_result(action, _effect),
    do: %{"action" => Atom.to_string(action), "status" => "applied"}

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "control_failed"

  defp transition_control_result(state, entry, status, attrs) do
    case Runs.transition_run_agent(entry.row, status, attrs,
           lease_owner: lease_owner(),
           lease_generation: entry.generation
         ) do
      {:ok, row} ->
        updated = %{entry | status: String.to_existing_atom(status), row: row}
        {:ok, put_in(state.agents[entry.agent_id], updated)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp release(entry, state, status, attrs) do
    release_row(entry.row, state, status, attrs)
  end

  defp release_row(row, _state, status, attrs) do
    Runs.release_run_agent_lease(
      row,
      lease_owner(),
      row.lease_generation,
      status,
      attrs
    )
  end

  defp validate_rows(_run_id, rows) when length(rows) > 32,
    do: {:error, :fleet_limit_exceeded}

  defp validate_rows(run_id, rows) do
    cond do
      rows == [] -> {:error, :empty_fleet}
      Enum.any?(rows, &(&1.run_id != run_id)) -> {:error, :agent_scope_mismatch}
      Enum.any?(rows, &(normalize_role(&1.role) not in @roles)) -> {:error, :invalid_role}
      true -> :ok
    end
  end

  defp validate_registration(run_id, row, role, pid) do
    case AgentRegistry.agent_registration(run_id, row.id) do
      {:ok, ^pid, %{role: ^role, generation: generation}}
      when generation == row.lease_generation ->
        :ok

      _ ->
        {:error, :agent_registration_mismatch}
    end
  end

  defp runtime_entry(state, agent_id, generation) do
    case Map.get(state.agents, agent_id) do
      %{generation: ^generation} = entry -> {:ok, entry}
      nil -> {:error, :agent_not_active}
      _stale -> {:error, :lease_lost}
    end
  end

  defp require_parent_run_status(state, allowed_statuses) do
    case Runs.get_run(state.run.id) do
      %IexCode.Runs.Run{status: status} = run ->
        if status in allowed_statuses,
          do: {:ok, %{state | run: run}},
          else: {:error, {:run_not_active, status}}

      nil ->
        {:error, :run_not_found}
    end
  end

  defp terminalize_budget_exhausted_fleet(state, failed_run, budget_error, caller_pid) do
    entries = Map.values(state.agents)

    Enum.each(entries, fn entry ->
      FleetControlToken.cancel(entry.token)
    end)

    attrs = %{
      error_message: failed_run.error_message,
      error_details: failed_run.error_details
    }

    case Runs.terminalize_run_agents(failed_run, "failed", attrs) do
      {:ok, _terminalized} ->
        Enum.each(entries, &demonitor_entry/1)

        {deferred_owner, immediate_entries} =
          Enum.split_with(entries, &usage_caller_linked_to_agent?(&1, caller_pid))

        # GenServer sends the reply from this callback before processing this
        # self-message. Siblings terminate immediately after the reply. An
        # owning child stays alive until its linked usage task exits after
        # observing the structured result.
        send(self(), {:terminate_budget_children, immediate_entries})

        {budget_callers, _refs} =
          Enum.reduce(deferred_owner, {state.budget_callers, []}, fn entry, {callers, refs} ->
            ref = Process.monitor(caller_pid)
            Process.send_after(self(), {:terminate_budget_owner, ref}, 5_000)
            {Map.put(callers, ref, entry), [ref | refs]}
          end)

        {:reply, {:error, budget_error},
         %{state | run: failed_run, agents: %{}, budget_callers: budget_callers}}

      {:error, reason} ->
        Logger.error(
          "Run #{failed_run.id} exhausted its budget but fleet terminalization failed: #{inspect(reason)}"
        )

        {:reply, {:error, {budget_error, {:fleet_terminalization_failed, reason}}},
         %{state | run: failed_run}}
    end
  end

  defp usage_caller_linked_to_agent?(%{pid: agent_pid}, caller_pid)
       when is_pid(agent_pid) and is_pid(caller_pid) do
    caller_pid == agent_pid or
      case Process.info(agent_pid, :links) do
        {:links, links} -> caller_pid in links
        nil -> false
      end
  end

  defp usage_caller_linked_to_agent?(_entry, _caller_pid), do: false

  defp runtime_error({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp runtime_error({:error, _reason}), do: "agent_work_failed"
  defp runtime_error(_result), do: nil

  defp demonitor_entry(%{ref: ref}) when is_reference(ref), do: Process.demonitor(ref, [:flush])
  defp demonitor_entry(_entry), do: :ok

  defp normalize_role(role) when role in @roles, do: role

  defp normalize_role(role) when is_binary(role),
    do: Enum.find(@roles, &(Atom.to_string(&1) == role))

  defp normalize_role(_role), do: nil

  defp public_entry(entry) do
    Map.take(entry, [:agent_id, :key, :role, :position, :generation, :pid, :status, :error])
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp lease_owner, do: Process.get(:fleet_lease_owner)
end

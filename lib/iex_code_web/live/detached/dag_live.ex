defmodule IexCodeWeb.Detached.DagLive do
  @moduledoc """
  Dedicated standalone LiveView for the DAG Topological Execution Map and Deep Research.
  Provides a comprehensive real-time view of stages, runnable/blocked/completed nodes,
  critical paths, and research synthesis.
  """

  use IexCodeWeb, :live_view
  require Logger

  alias IexCode.Runs
  alias IexCode.Runs.DagProjection
  alias IexCode.Runs.DagScheduler
  alias IexCode.Sessions
  alias IexCodeWeb.DagComponents

  @impl true
  def mount(%{"id" => session_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(IexCode.PubSub, "runs:session:#{session_id}")
      Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session_id}:research_results")
      Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session_id}")
    end

    session = Sessions.get_session!(session_id)

    run =
      case Runs.list_runs(session_id: session_id) do
        runs when is_list(runs) and runs != [] ->
          Enum.find(runs, &(&1.status in ["running", "queued"])) || List.first(runs)

        _ ->
          nil
      end

    steps = if run, do: Runs.list_steps(run.id), else: []
    projection = build_projection(run, steps)

    {:ok,
     socket
     |> assign(:page_title, "DAG Execution Map — #{session_id}")
     |> assign(:current_scope, nil)
     |> assign(:session, session)
     |> assign(:session_id, session_id)
     |> assign(:run, run)
     |> assign(:steps, steps)
     |> assign(:selected_step, List.first(steps))
     |> assign(:projection, projection)
     |> assign(:research_results, [])}
  end

  @impl true
  def handle_event("select_step", %{"id" => step_id}, socket) do
    step = Enum.find(socket.assigns.steps, &(&1.id == step_id or to_string(&1.id) == step_id))
    {:noreply, assign(socket, :selected_step, step)}
  end

  # PubSub Handlers

  @impl true
  def handle_info({:run_updated, %{id: run_id} = updated_run}, socket) do
    if is_nil(socket.assigns.run) or socket.assigns.run.id == run_id do
      steps =
        try do
          Runs.list_steps(run_id)
        rescue
          _ -> []
        end

      projection = build_projection(updated_run, steps)

      {:noreply,
       socket
       |> assign(:run, updated_run)
       |> assign(:steps, steps)
       |> assign(:projection, projection)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:run_step_updated, %{run_id: run_id} = _updated_step}, socket) do
    if is_nil(socket.assigns.run) or socket.assigns.run.id == run_id do
      steps =
        try do
          Runs.list_steps(run_id)
        rescue
          _ -> []
        end

      projection = build_projection(socket.assigns.run, steps)

      {:noreply,
       socket
       |> assign(:steps, steps)
       |> assign(:projection, projection)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:research_result, result}, socket) do
    results = [result | socket.assigns.research_results] |> Enum.uniq_by(&Map.get(&1, :id, &1))
    {:noreply, assign(socket, :research_results, results)}
  end

  @impl true
  def handle_info({:research_result_updated, result}, socket) do
    results = [result | socket.assigns.research_results] |> Enum.uniq_by(&Map.get(&1, :id, &1))
    {:noreply, assign(socket, :research_results, results)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Helpers

  defp build_projection(nil, _steps) do
    %{
      engine: "dag_v1",
      available?: false,
      revision: 0,
      summary: %{},
      layers: [],
      error_code: "no_active_dag_run"
    }
  end

  defp build_projection(run, steps) do
    attempts =
      try do
        DagScheduler.list_attempts(run, limit: 1_000)
      rescue
        _ -> []
      end

    case DagProjection.build(run, steps, attempts) do
      {:ok, projection} ->
        projection

      {:error, reason} ->
        %{
          engine: "dag_v1",
          available?: false,
          revision: run[:event_sequence] || 0,
          summary: %{},
          layers: [],
          error_code: if(is_binary(reason), do: reason, else: inspect(reason))
        }
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div
        id="detached-dag-container"
        class="flex flex-col h-screen w-screen bg-[#0a0d12] overflow-hidden text-gray-200"
      >
        <!-- Header -->
        <header class="flex items-center justify-between px-4 py-2.5 bg-[#161b22] border-b border-[#30363d] shrink-0">
          <div class="flex items-center gap-3">
            <div class="flex items-center gap-2">
              <span class="w-3 h-3 rounded-full bg-cyan-400 shadow-[0_0_8px_rgba(34,211,238,0.5)] animate-pulse"></span>
              <span class="font-mono text-sm font-semibold text-white tracking-wide">DAG TOPOLOGICAL MAP</span>
            </div>
            <span class="text-xs px-2 py-0.5 rounded bg-zinc-800 text-zinc-400 font-mono">
              Session: {@session_id}
            </span>
            <%= if @run do %>
              <span class="text-xs px-2 py-0.5 rounded bg-cyan-950/60 border border-cyan-800/50 text-cyan-300 font-mono">
                Run: {@run.id} ({@run.status})
              </span>
            <% end %>
          </div>

          <div class="flex items-center gap-3 text-xs font-mono">
            <div class="flex items-center gap-2 bg-[#0d1117] px-2.5 py-1 rounded border border-[#30363d]">
              <span class="text-zinc-500">Engine:</span>
              <span class="text-cyan-300 font-semibold">{@projection[:engine] || "dag_v1"}</span>
            </div>
            <div class="flex items-center gap-2 bg-[#0d1117] px-2.5 py-1 rounded border border-[#30363d]">
              <span class="text-zinc-500">Nodes:</span>
              <span class="text-emerald-300 font-semibold">
                {(@projection[:layers] || []) |> List.flatten() |> length()}
              </span>
            </div>
          </div>
        </header>

        <!-- Main Content: Left DAG Projection, Right Step Details -->
        <div class="flex flex-1 min-h-0 overflow-hidden">
          <main id="dag-execution-projection" class="flex-1 overflow-auto p-4 bg-[#0a0d12]">
            <%= if @projection[:layers] == [] do %>
              <div class="h-full flex flex-col items-center justify-center text-center p-8 border border-dashed border-zinc-800 rounded-xl">
                <.icon name="hero-rectangle-group" class="w-12 h-12 text-zinc-600 mb-3" />
                <h3 class="text-sm font-semibold text-zinc-300">No Active DAG Execution</h3>
                <p class="text-xs text-zinc-500 max-w-sm mt-1">
                  Launch a DAG run or Deep Research session from the primary workspace to see real-time topological layers.
                </p>
              </div>
            <% else %>
              <DagComponents.dag_projection projection={@projection} />
            <% end %>
          </main>

          <!-- Step Inspector Sidebar -->
          <aside class="w-80 border-l border-[#30363d] bg-[#0d1117] flex flex-col shrink-0 text-xs font-mono">
            <div class="p-3 border-b border-[#30363d] font-semibold text-zinc-300 flex items-center justify-between">
              <span>STEP INSPECTOR</span>
              <span class="text-[10px] text-zinc-500">{length(@steps)} Total</span>
            </div>

            <!-- Steps List -->
            <div class="flex-1 overflow-y-auto p-2 space-y-1">
              <%= for step <- @steps do %>
                <div
                  phx-click="select_step"
                  phx-value-id={step.id}
                  class={[
                    "p-2 rounded border cursor-pointer transition-smooth",
                    @selected_step && @selected_step.id == step.id &&
                      "bg-[#161b22] border-cyan-500/50 text-white",
                    (!@selected_step or @selected_step.id != step.id) &&
                      "border-[#21262d] bg-[#0a0d12] hover:bg-[#161b22] text-zinc-400"
                  ]}
                >
                  <div class="flex items-center justify-between mb-1">
                    <span class="font-bold truncate">{step[:title] || step[:kind] || "Step #{step.id}"}</span>
                    <span class={[
                      "text-[10px] px-1.5 py-0.2 rounded font-semibold",
                      step[:status] in ["completed", :completed] &&
                        "bg-emerald-950/70 text-emerald-300",
                      step[:status] in ["running", :running] &&
                        "bg-cyan-950/70 text-cyan-300 animate-pulse",
                      step[:status] in ["failed", :failed] && "bg-rose-950/70 text-rose-300",
                      step[:status] in ["blocked", :blocked] && "bg-amber-950/70 text-amber-300",
                      step[:status] in ["ready", :ready] && "bg-blue-950/70 text-blue-300"
                    ]}>
                      {step[:status] || "pending"}
                    </span>
                  </div>
                  <div class="text-[10px] text-zinc-500 truncate">
                    Dependencies: {length(step[:dependencies] || [])}
                  </div>
                </div>
              <% end %>
            </div>

            <!-- Details of Selected Step -->
            <%= if @selected_step do %>
              <div class="p-3 border-t border-[#30363d] bg-[#161b22]/50 space-y-2 max-h-48 overflow-y-auto">
                <div class="text-[11px] font-semibold text-cyan-300">
                  {@selected_step[:title] || "Step Details"}
                </div>
                <div class="text-[10px] text-zinc-400 space-y-1">
                  <div><span class="text-zinc-500">ID:</span> {@selected_step.id}</div>
                  <div><span class="text-zinc-500">Status:</span> {@selected_step[:status]}</div>
                  <div>
                    <span class="text-zinc-500">Kind:</span> {@selected_step[:kind] || "standard"}
                  </div>
                </div>
              </div>
            <% end %>
          </aside>
        </div>
      </div>
    </Layouts.app>
    """
  end
end

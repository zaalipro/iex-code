defmodule IexCodeWeb.RunComponents do
  @moduledoc """
  UI primitives for the durable asynchronous run control plane.

  The component deliberately renders persisted run projections rather than
  process-local state. A LiveView can therefore reconnect and replay the same
  ordered journal after the browser or application shell has been closed.
  """

  use IexCodeWeb, :html

  alias IexCodeWeb.DagComponents

  attr :runs, :list, required: true
  attr :run_count, :integer, default: 0
  attr :run_counts, :map, default: %{active: 0, queued: 0, attention: 0, approvals: 0}
  attr :selected_run, :any, default: nil
  attr :steps, :list, default: []
  attr :approvals, :list, default: []
  attr :artifacts, :list, default: []
  attr :controls, :list, default: []
  attr :run_manifest, :map, default: %{}
  attr :events, :any, required: true
  attr :stats, :map, default: %{}
  attr :workspace_locks, :list, default: []
  attr :agents, :any, default: []
  attr :agent_count, :integer, default: 0

  attr :fleet_summary, :map,
    default: %{active: 0, paused: 0, attention: 0, recovering: 0, tokens: 0}

  attr :fleet_loading, :boolean, default: false
  attr :agent_guidance, :map, default: %{}
  attr :agent_receipts, :map, default: %{}
  attr :dag_projection, :map, default: nil

  def run_control_plane(assigns) do
    active_workspace_locks =
      Enum.filter(assigns.workspace_locks, &(lock_value(&1, :status) in ["held", "waiting"]))

    held_workspace_locks =
      Enum.filter(active_workspace_locks, &(lock_value(&1, :status) == "held"))

    waiting_workspace_locks =
      Enum.filter(active_workspace_locks, &(lock_value(&1, :status) == "waiting"))

    selected_lock_state = run_workspace_lock_state(assigns.selected_run, active_workspace_locks)

    selected_workspace_lock =
      selected_run_workspace_lock(
        assigns.selected_run,
        active_workspace_locks,
        selected_lock_state
      )

    workspace_lock_state =
      cond do
        selected_lock_state in ["held", "waiting"] -> selected_lock_state
        held_workspace_locks != [] -> "held"
        waiting_workspace_locks != [] -> "waiting"
        true -> "free"
      end

    assigns =
      assigns
      |> assign(:steering_form, to_form(%{"steering" => ""}))
      |> assign(:active_workspace_locks, active_workspace_locks)
      |> assign(:held_workspace_locks, held_workspace_locks)
      |> assign(:waiting_workspace_locks, waiting_workspace_locks)
      |> assign(:selected_lock_state, selected_lock_state)
      |> assign(:selected_workspace_lock, selected_workspace_lock)
      |> assign(:workspace_lock_state, workspace_lock_state)

    ~H"""
    <section id="async-run-control" aria-labelledby="async-run-heading" class="mission-control">
      <header class="mission-header">
        <div class="mission-heading-group">
          <div class="mission-heading-icon" aria-hidden="true">
            <.icon name="hero-command-line" class="h-5 w-5" />
          </div>
          <div>
            <h2 id="async-run-heading" class="mission-title">Mission Control</h2>
            <p class="mission-subtitle">Track background runs and keep work moving.</p>
          </div>
        </div>

        <div class="mission-header-actions">
          <div
            id="async-dispatcher-status"
            role="status"
            data-dispatcher-online={to_string(Map.get(@stats, :online, false))}
            class={[
              "mission-dispatcher",
              Map.get(@stats, :online, false) &&
                "border-success/20 bg-success/[0.06] text-success",
              !Map.get(@stats, :online, false) &&
                "border-danger/20 bg-danger/[0.06] text-danger"
            ]}
          >
            <span class={[
              "h-1.5 w-1.5 rounded-full",
              Map.get(@stats, :online, false) && "animate-pulse bg-success",
              !Map.get(@stats, :online, false) && "bg-danger"
            ]}></span>
            <%= if Map.get(@stats, :online, false) do %>
              <span>Dispatcher online</span>
              <span class="mission-dispatcher-capacity">{Map.get(@stats, :capacity, 0)} worker slots</span>
            <% else %>
              <span>Dispatcher offline</span>
              <span class="mission-dispatcher-capacity">Controls unavailable</span>
            <% end %>
          </div>
          <button
            id="async-run-new"
            type="button"
            phx-click={
              JS.push("set_dispatch_mode", value: %{mode: "background"})
              |> JS.focus(to: "#prompt-textarea")
            }
            class="mission-button mission-button-primary ui-depth-effect"
          >
            <.icon name="hero-plus" class="h-4 w-4" /> New run
          </button>
        </div>
      </header>

      <section
        id="workspace-lock-overview"
        aria-labelledby="workspace-lock-heading"
        aria-live="polite"
        aria-atomic="true"
        data-lock-state={@workspace_lock_state}
        class={[
          "mission-workspace-strip rounded-2xl border transition-colors",
          @workspace_lock_state == "free" && "border-line",
          @workspace_lock_state == "held" && "border-success/25",
          @workspace_lock_state == "waiting" && "border-warning/30"
        ]}
      >
        <div class="mission-workspace-strip-inner">
          <div class="mission-workspace-summary">
            <span class={[
              "mission-workspace-icon flex h-7 w-7 shrink-0 items-center justify-center rounded-lg",
              @workspace_lock_state == "free" &&
                "border-line bg-raised text-subtle",
              @workspace_lock_state == "held" &&
                "border-success/25 bg-success/[0.07] text-success",
              @workspace_lock_state == "waiting" &&
                "border-warning/30 bg-warning/[0.08] text-warning"
            ]}>
              <.icon
                name={
                  if @workspace_lock_state == "free", do: "hero-lock-open", else: "hero-lock-closed"
                }
                class="h-4 w-4"
              />
            </span>

            <div class="mission-workspace-copy min-w-0">
              <div class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
                <h3
                  id="workspace-lock-heading"
                  class="text-xs font-medium text-muted"
                >
                  Workspace access
                </h3>
                <span
                  id="workspace-lock-summary"
                  class={[
                    "mission-workspace-state text-xs font-medium",
                    @workspace_lock_state == "free" && "text-subtle",
                    @workspace_lock_state == "held" && "text-success",
                    @workspace_lock_state == "waiting" && "text-warning"
                  ]}
                >
                  {workspace_lock_summary(
                    @workspace_lock_state,
                    @selected_lock_state,
                    selected_or_first(
                      @selected_workspace_lock,
                      @held_workspace_locks
                    ),
                    selected_or_first(
                      @selected_workspace_lock,
                      @waiting_workspace_locks
                    )
                  )}
                </span>
              </div>
              <p
                id="workspace-lock-context"
                class="mission-workspace-context truncate text-[11px] leading-5 text-subtle"
              >
                {workspace_lock_context(
                  @workspace_lock_state,
                  @selected_lock_state,
                  selected_or_first(@selected_workspace_lock, @held_workspace_locks),
                  selected_or_first(@selected_workspace_lock, @waiting_workspace_locks)
                )}
              </p>
            </div>
          </div>

          <div class="mission-workspace-resources">
            <div class="flex items-center gap-3 text-[11px] tabular-nums text-subtle">
              <span
                id="workspace-lock-held-count"
                class="mission-resource-count"
              >
                <strong class="font-semibold text-muted">{length(@held_workspace_locks)}</strong> held
              </span>
              <span
                id="workspace-lock-waiting-count"
                class="mission-resource-count"
              >
                <strong class="font-semibold text-muted">{length(@waiting_workspace_locks)}</strong>
                waiting
              </span>
            </div>

            <details
              :if={@active_workspace_locks != []}
              id="workspace-lock-details"
              class="group relative"
            >
              <summary class="flex min-h-8 cursor-pointer list-none items-center gap-1.5 rounded-full border border-line bg-raised px-2.5 font-mono text-[11px] text-muted transition-colors hover:border-line hover:text-content focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent/60 [&::-webkit-details-marker]:hidden">
                Details
                <.icon
                  name="hero-chevron-down"
                  class="h-3 w-3 transition-transform group-open:rotate-180"
                />
              </summary>
              <div class="absolute right-0 top-full z-20 mt-2 grid max-h-80 w-[min(42rem,calc(100vw-2rem))] overflow-y-auto rounded-2xl border border-line bg-inset mission-popover-shadow md:grid-cols-2">
                <article
                  :for={lock <- @active_workspace_locks}
                  id={"workspace-lock-#{lock_value(lock, :id)}"}
                  data-lock-status={lock_value(lock, :status)}
                  class="min-w-0 border-b border-line px-3.5 py-3 md:border-r md:[&:nth-child(even)]:border-r-0"
                >
                  <div class="flex items-start justify-between gap-3">
                    <div class="min-w-0">
                      <p
                        class="truncate font-mono text-[11px] font-medium text-muted"
                        title={workspace_lock_resource(lock)}
                      >
                        {workspace_lock_resource(lock)}
                      </p>
                      <p class="mt-1 truncate text-[11px] text-subtle">
                        Owner · {workspace_lock_owner(lock)}
                      </p>
                    </div>
                    <span class={[
                      "shrink-0 border px-1.5 py-0.5 font-mono text-[10px] uppercase tracking-wider",
                      lock_value(lock, :status) == "held" &&
                        "border-success/20 bg-success/[0.06] text-success",
                      lock_value(lock, :status) == "waiting" &&
                        "border-warning/25 bg-warning/[0.07] text-warning"
                    ]}>
                      {lock_value(lock, :status)}
                    </span>
                  </div>
                  <div class="mt-2 flex min-w-0 items-center justify-between gap-3 font-mono text-[10px] uppercase tracking-wider text-subtle">
                    <span>{display_value(lock_value(lock, :mode), "access")}</span>
                    <span
                      class="truncate normal-case tracking-normal"
                      title={workspace_lock_lease_title(lock)}
                    >
                      {workspace_lock_lease(lock)}
                    </span>
                  </div>
                </article>
              </div>
            </details>
          </div>
        </div>
      </section>

      <div
        id="async-run-metrics"
        role="status"
        aria-live="polite"
        aria-atomic="true"
        data-pending-approvals={Map.get(@run_counts, :approvals, 0)}
        class="mission-metrics"
      >
        <.run_metric label="Active now" value={Map.get(@run_counts, :active, 0)} tone="emerald" />
        <.run_metric label="Queued" value={Map.get(@run_counts, :queued, 0)} tone="blue" />
        <.run_metric label="Needs attention" value={Map.get(@run_counts, :attention, 0)} tone="rose" />
        <.run_metric label="Approvals" value={Map.get(@run_counts, :approvals, 0)} tone="amber" />
      </div>

      <div class="mission-run-workbench">
        <aside class="mission-run-ledger" aria-label="Run ledger">
          <div class="mission-panel-heading">
            <div>
              <h3 class="text-sm font-semibold text-content">Run ledger</h3>
              <p class="mt-0.5 text-[11px] text-subtle">
                Newest first
              </p>
            </div>
            <span class="mission-count-badge">{@run_count}</span>
          </div>

          <div id="async-run-list" class="mission-run-list">
            <div :if={@runs == []} id="async-runs-empty" class="mission-ledger-empty">
              <div class="mission-empty-icon">
                <.icon name="hero-queue-list" class="h-4 w-4" />
              </div>
              <p class="text-sm font-medium text-content">No runs yet</p>
              <p class="mt-1 text-[11px] leading-5 text-subtle">
                Your background runs will appear here, with status and progress at a glance.
              </p>
            </div>

            <button
              :for={run <- @runs}
              id={"async-run-#{run.id}"}
              type="button"
              phx-click="select_async_run"
              phx-value-id={run.id}
              aria-pressed={@selected_run && @selected_run.id == run.id}
              data-run-status={run.status}
              data-workspace-lock-state={run_workspace_lock_state(run, @active_workspace_locks)}
              class={[
                "mission-run-row group w-full rounded-xl border text-left transition-colors",
                @selected_run && @selected_run.id == run.id &&
                  "mission-run-row-selected",
                (!@selected_run || @selected_run.id != run.id) &&
                  "border-transparent hover:bg-raised"
              ]}
            >
              <div class="mb-2 flex items-center justify-between gap-2">
                <.run_status status={run.status} />
                <span class="font-mono text-[11px] tabular-nums text-subtle">
                  #{String.slice(run.id, 0, 7)}
                </span>
              </div>
              <p class="mission-run-objective line-clamp-2 text-[13px] font-medium leading-5 text-content">
                {run.objective}
              </p>
              <div class="mt-2 flex items-center justify-between gap-2 text-[11px] text-subtle">
                <span>{run.kind |> String.replace("_", " ")}</span>
                <span class="tabular-nums">{min(max(run.progress || 0, 0), 100)}%</span>
              </div>
              <div
                :if={run_workspace_lock_state(run, @active_workspace_locks) != "none"}
                class={[
                  "mt-2 flex items-center gap-1.5 font-mono text-[10px] uppercase tracking-wider",
                  run_workspace_lock_state(run, @active_workspace_locks) == "held" &&
                    "text-success",
                  run_workspace_lock_state(run, @active_workspace_locks) == "waiting" &&
                    "text-warning"
                ]}
              >
                <.icon
                  name={
                    if run_workspace_lock_state(run, @active_workspace_locks) == "held",
                      do: "hero-lock-closed",
                      else: "hero-clock"
                  }
                  class="h-3 w-3"
                />
                <span>
                  {if run_workspace_lock_state(run, @active_workspace_locks) == "held",
                    do: "owns workspace",
                    else: "waiting for workspace"}
                </span>
              </div>
              <div class="mission-progress-track mt-2 overflow-hidden bg-raised">
                <div
                  role="progressbar"
                  aria-label={"#{run.objective} progress"}
                  aria-valuemin="0"
                  aria-valuemax="100"
                  aria-valuenow={min(max(run.progress || 0, 0), 100)}
                  class={[
                    "h-full transition-[width] duration-300",
                    run.status == "failed" && "bg-danger",
                    run.status == "interrupted" && "bg-warning",
                    run.status not in ["failed", "interrupted"] && "bg-success"
                  ]}
                  style={"width: #{min(max(run.progress || 0, 0), 100)}%"}
                >
                </div>
              </div>
            </button>
          </div>
        </aside>

        <div class="mission-run-detail-panel min-w-0">
          <div
            :if={is_nil(@selected_run)}
            id="async-run-selection-empty"
            class="mission-selection-empty"
          >
            <div class="mission-empty-icon mission-empty-icon-accent" aria-hidden="true">
              <.icon
                name={if @runs == [], do: "hero-command-line", else: "hero-cursor-arrow-rays"}
                class="h-5 w-5"
              />
            </div>
            <h3 class="mission-empty-title">
              {if @runs == [], do: "Start your first background run", else: "Select a run to inspect"}
            </h3>
            <p class="mission-empty-copy">
              <%= if @runs == [] do %>
                Describe a task in the composer, review your run setup, and queue it in Background mode.
                Its progress, agents, and saved results will appear here.
              <% else %>
                Choose a run from the ledger to review progress, manage agents, and inspect its activity.
              <% end %>
            </p>
            <button
              :if={@runs == []}
              id="async-run-empty-compose"
              type="button"
              phx-click={
                JS.push("set_dispatch_mode", value: %{mode: "background"})
                |> JS.focus(to: "#prompt-textarea")
              }
              class="mission-button mission-button-primary ui-depth-effect"
            >
              Write a task <.icon name="hero-arrow-down" class="h-3.5 w-3.5" />
            </button>
            <span :if={@runs == []} class="mission-empty-note">
              <.icon name="hero-bookmark" class="h-3.5 w-3.5" />
              Run history stays available when you reconnect.
            </span>
          </div>

          <div
            :if={@selected_run}
            id="async-run-detail"
            data-run-status={@selected_run.status}
            class="mission-run-detail min-w-0"
          >
            <div class="mission-detail-overview">
              <div class="mission-detail-heading">
                <div class="min-w-0 max-w-3xl">
                  <div class="mb-2 flex flex-wrap items-center gap-2">
                    <.run_status status={@selected_run.status} />
                    <span class="rounded-md border border-line px-2 py-0.5 text-[11px] font-medium text-muted">
                      {@selected_run.mode}
                    </span>
                    <span class="font-mono text-[11px] uppercase tracking-wider text-subtle">
                      {@selected_run.priority} priority
                    </span>
                  </div>
                  <h3 class="mission-detail-title">
                    {@selected_run.objective}
                  </h3>
                  <p
                    :if={@selected_run.error_message}
                    class="mt-3 border-l-2 border-danger pl-3 text-xs leading-5 text-danger"
                  >
                    {@selected_run.error_message}
                  </p>
                </div>

                <div
                  id="async-run-actions"
                  class="mission-run-actions flex shrink-0 flex-wrap items-center gap-2"
                >
                  <button
                    :if={@selected_run.status == "running"}
                    id="pause-async-run"
                    type="button"
                    phx-click="pause_async_run"
                    phx-value-id={@selected_run.id}
                    phx-disable-with="Pausing…"
                    class="mission-button inline-flex items-center gap-1.5 border border-warning/30 bg-warning/[0.07] px-3 py-2 font-mono text-[11px] font-semibold text-warning transition-colors hover:bg-warning/15 disabled:cursor-wait disabled:opacity-60"
                  >
                    <.icon name="hero-pause" class="h-3.5 w-3.5" /> Pause
                  </button>
                  <button
                    :if={@selected_run.status == "draft"}
                    id="start-async-run"
                    type="button"
                    phx-click="start_async_run"
                    phx-value-id={@selected_run.id}
                    phx-disable-with="Starting…"
                    class="mission-button inline-flex items-center gap-1.5 border border-success/30 bg-success/[0.07] px-3 py-2 font-mono text-[11px] font-semibold text-success transition-colors hover:bg-success/15 disabled:cursor-wait disabled:opacity-60"
                  >
                    <.icon name="hero-play" class="h-3.5 w-3.5" /> Start
                  </button>
                  <button
                    :if={@selected_run.status == "paused"}
                    id="resume-async-run"
                    type="button"
                    phx-click="resume_async_run"
                    phx-value-id={@selected_run.id}
                    phx-disable-with="Resuming…"
                    class="mission-button inline-flex items-center gap-1.5 border border-success/30 bg-success/[0.07] px-3 py-2 font-mono text-[11px] font-semibold text-success transition-colors hover:bg-success/15 disabled:cursor-wait disabled:opacity-60"
                  >
                    <.icon name="hero-play" class="h-3.5 w-3.5" /> Resume
                  </button>
                  <button
                    :if={@selected_run.status in ["draft", "queued", "running", "paused"]}
                    id="cancel-async-run"
                    type="button"
                    phx-click="cancel_async_run"
                    phx-value-id={@selected_run.id}
                    data-confirm={
                      if(@selected_run.status == "draft",
                        do:
                          "Cancel this draft? It will be marked cancelled without starting any work.",
                        else: "Cancel this run? Execution will stop after the request is persisted."
                      )
                    }
                    phx-disable-with="Cancelling…"
                    class="mission-button inline-flex items-center gap-1.5 border border-danger/30 bg-danger/[0.07] px-3 py-2 font-mono text-[11px] font-semibold text-danger transition-colors hover:bg-danger/15 disabled:cursor-wait disabled:opacity-60"
                  >
                    <.icon name="hero-stop" class="h-3.5 w-3.5" /> Cancel
                  </button>
                  <button
                    :if={
                      @selected_run.status in ["failed", "cancelled", "interrupted"] &&
                        @selected_run.attempt < @selected_run.max_attempts
                    }
                    id="retry-async-run"
                    type="button"
                    phx-click="retry_async_run"
                    phx-value-id={@selected_run.id}
                    phx-disable-with="Retrying…"
                    class="mission-button mission-button-primary inline-flex items-center gap-1.5 bg-accent px-3 py-2 font-mono text-[11px] font-semibold text-accent-ink transition-colors hover:bg-accent-strong disabled:cursor-wait disabled:opacity-60"
                  >
                    <.icon name="hero-arrow-path" class="h-3.5 w-3.5" /> Retry on current workspace
                  </button>
                </div>
              </div>

              <div class="mission-run-facts">
                <.run_fact label="Progress" value={"#{@selected_run.progress || 0}%"} />
                <.run_fact
                  label="Attempt"
                  value={"#{@selected_run.attempt}/#{@selected_run.max_attempts}"}
                />
                <.run_fact label="Events" value={to_string(@selected_run.event_sequence || 0)} />
              </div>

              <div
                id="async-run-budget-meters"
                class="mission-budget-grid"
              >
                <.budget_meter
                  id="async-run-token-budget"
                  label="Tokens"
                  actual={(@selected_run.input_tokens || 0) + (@selected_run.output_tokens || 0)}
                  limit={@selected_run.token_budget}
                  unit="tokens"
                />
                <.budget_meter
                  id="async-run-cost-budget"
                  label="Cost · reported or reserved"
                  actual={@selected_run.cost_cents || 0}
                  limit={@selected_run.cost_budget_cents}
                  unit="cost"
                  limit_prefix="target"
                />
                <.budget_meter
                  id="async-run-time-budget"
                  label="Elapsed"
                  actual={elapsed_ms(@selected_run)}
                  limit={@selected_run.time_budget_ms}
                  unit="time"
                />
              </div>

              <div class="mission-steering-grid">
                <.form
                  :if={@selected_run.execution_engine != "dag_v1"}
                  for={@steering_form}
                  id="async-run-steering-form"
                  phx-submit="steer_async_run"
                  class="mission-detail-section rounded-xl border border-line bg-surface p-3"
                >
                  <.input
                    type="hidden"
                    id="async-run-steering-run-id"
                    name="run_id"
                    value={@selected_run.id}
                  />
                  <div class="mb-2 flex items-center justify-between gap-3">
                    <div>
                      <h4 class="text-xs font-semibold text-content">
                        Live steering
                      </h4>
                      <p class="mt-0.5 text-[11px] text-subtle">
                        Send a new instruction to this run
                      </p>
                    </div>
                    <span class="font-mono text-[10px] text-subtle">
                      #{String.slice(@selected_run.id, 0, 7)}
                    </span>
                  </div>
                  <div class="flex items-end gap-2">
                    <div class="min-w-0 flex-1">
                      <.input
                        field={@steering_form[:steering]}
                        id="async-run-steering-input"
                        name="steering"
                        type="text"
                        label="Steering instruction"
                        placeholder="Refine scope, redirect research, or add a constraint…"
                        disabled={@selected_run.status not in ["running", "paused"]}
                        class="mission-input block w-full border border-line bg-inset px-3 py-2 text-xs text-content outline-none transition-colors placeholder:text-subtle focus:border-accent/60 disabled:cursor-not-allowed disabled:opacity-50"
                      />
                    </div>
                    <button
                      id="async-run-steering-submit"
                      type="submit"
                      disabled={@selected_run.status not in ["running", "paused"]}
                      class="mission-button mission-button-primary mb-0.5 inline-flex h-9 shrink-0 items-center gap-1.5 bg-accent px-3 font-mono text-[11px] font-semibold uppercase tracking-wider text-accent-ink transition-colors hover:bg-accent-strong disabled:cursor-not-allowed disabled:bg-raised disabled:text-subtle"
                    >
                      <.icon name="hero-arrow-up-right" class="h-3.5 w-3.5" /> Steer
                    </button>
                  </div>
                </.form>

                <div
                  :if={@selected_run.kind == "deep_research"}
                  id="async-run-research-manifest"
                  class="mission-detail-section rounded-xl border border-line bg-surface p-3"
                >
                  <div class="mb-3 flex items-center justify-between gap-3">
                    <div>
                      <h4 class="text-xs font-semibold text-content">
                        Research manifest
                      </h4>
                      <p class="mt-0.5 text-[11px] text-subtle">Research settings for this run</p>
                    </div>
                    <span class={[
                      "h-1.5 w-1.5 rounded-full",
                      manifest_enabled?(@run_manifest) && "bg-accent",
                      !manifest_enabled?(@run_manifest) && "bg-raised"
                    ]}></span>
                  </div>
                  <div class="grid grid-cols-3 gap-px bg-raised">
                    <.manifest_fact
                      label="Mode"
                      value={manifest_value(@run_manifest, :mode, "Not requested")}
                    />
                    <.manifest_fact
                      label="Provider"
                      value={manifest_providers(@run_manifest)}
                    />
                    <.manifest_fact
                      label="Depth"
                      value={manifest_value(@run_manifest, :depth, "Unset")}
                    />
                  </div>
                </div>
              </div>
            </div>

            <.agent_fleet
              run={@selected_run}
              agents={@agents}
              agent_count={@agent_count}
              summary={@fleet_summary}
              loading={@fleet_loading}
              guidance={@agent_guidance}
              receipts={@agent_receipts}
            />

            <div
              :if={@selected_run.execution_engine == "dag_v1" and @dag_projection}
              id="async-run-dag-projection"
              class="border-b border-line p-4 md:p-5"
            >
              <DagComponents.dag_projection projection={@dag_projection} />
            </div>

            <div class="mission-activity-grid">
              <div
                id="async-run-graph-and-controls"
                data-graph-mode={
                  if @selected_run.execution_engine == "dag_v1", do: "dag", else: "legacy"
                }
                class="mission-activity-column"
              >
                <div
                  :if={@selected_run.execution_engine != "dag_v1"}
                  class="mb-4 flex items-center justify-between"
                >
                  <h4 class="text-sm font-semibold tracking-tight text-content">
                    Execution graph
                  </h4>
                  <span class="font-mono text-[11px] text-subtle">{length(@steps)} nodes</span>
                </div>

                <div
                  :if={@selected_run.execution_engine != "dag_v1"}
                  id="async-run-steps"
                  class="space-y-2"
                >
                  <div
                    :if={@steps == []}
                    class="rounded-xl border border-dashed border-line px-3 py-6 text-center text-xs text-subtle"
                  >
                    Steps appear when the dispatcher claims this run.
                  </div>
                  <div
                    :for={step <- @steps}
                    id={"async-run-step-#{step.id}"}
                    class="relative rounded-xl border border-line bg-surface px-3 py-3"
                  >
                    <div class="flex items-start gap-3">
                      <span class={[
                        "mt-1.5 h-2 w-2 shrink-0 rounded-full",
                        step.status == "completed" && "bg-success",
                        step.status == "running" && "animate-pulse bg-accent",
                        step.status in ["failed", "cancelled"] && "bg-danger",
                        step.status in ["paused", "interrupted", "waiting_approval"] &&
                          "bg-warning",
                        step.status in ["pending", "ready", "blocked", "skipped"] && "bg-subtle"
                      ]}></span>
                      <div class="min-w-0 flex-1">
                        <div class="flex items-center justify-between gap-3">
                          <p class="truncate text-xs font-medium text-muted">{step.title}</p>
                          <span class="font-mono text-[10px] uppercase tracking-wider text-subtle">{step.status}</span>
                        </div>
                        <p
                          :if={step.depends_on != []}
                          class="mt-1 truncate font-mono text-[10px] text-subtle"
                        >
                          waits for {Enum.join(step.depends_on, ", ")}
                        </p>
                        <div class="mt-2 h-px bg-raised">
                          <div
                            role="progressbar"
                            aria-label={"#{step.title} progress"}
                            aria-valuemin="0"
                            aria-valuemax="100"
                            aria-valuenow={min(max(step.progress || 0, 0), 100)}
                            class="h-full bg-accent"
                            style={"width: #{min(max(step.progress || 0, 0), 100)}%"}
                          >
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>

                <div id="async-run-control-timeline" class="mt-5 border-t border-line pt-4">
                  <div class="mb-3 flex items-center justify-between gap-3">
                    <div>
                      <h4 class="text-sm font-semibold tracking-tight text-content">
                        Control history
                      </h4>
                      <p class="mt-1 text-[11px] text-subtle">
                        Instructions and lifecycle actions
                      </p>
                    </div>
                    <span class="font-mono text-[11px] tabular-nums text-subtle">
                      {length(@controls)} entries
                    </span>
                  </div>
                  <div class="mission-control-timeline relative border-l border-line pl-4">
                    <div
                      :if={@controls == []}
                      id="async-run-controls-empty"
                      class="rounded-xl border border-dashed border-line px-3 py-5 text-center text-xs text-subtle"
                    >
                      No operator controls have been recorded.
                    </div>
                    <article
                      :for={control <- @controls}
                      id={"async-run-control-entry-#{control_value(control, :id, control_fingerprint(control))}"}
                      data-status={control_value(control, :status, "recorded")}
                      class="relative mb-2 rounded-xl border border-line bg-surface px-3 py-3 last:mb-0"
                    >
                      <span class={[
                        "absolute -left-[1.28rem] top-4 h-2 w-2 rounded-full ring-4 ring-surface",
                        control_tone(control_value(control, :status, "recorded"))
                      ]}></span>
                      <div class="flex items-start justify-between gap-3">
                        <div class="min-w-0">
                          <p class="truncate text-xs font-medium text-muted">
                            {control_title(control)}
                          </p>
                          <p class="mt-1 line-clamp-3 text-[11px] leading-5 text-subtle">
                            {control_summary(control)}
                          </p>
                        </div>
                        <span class="shrink-0 font-mono text-[10px] uppercase tracking-wider text-subtle">
                          {control_value(control, :status, "recorded")}
                        </span>
                      </div>
                    </article>
                  </div>
                </div>

                <div :if={@approvals != []} class="mt-5 border-t border-line pt-4">
                  <h4 class="mb-3 text-sm font-semibold tracking-tight text-content">
                    Approval gates
                  </h4>
                  <div
                    :for={approval <- @approvals}
                    id={"async-run-approval-#{approval.id}"}
                    class="mb-2 rounded-xl border border-warning/20 bg-warning/[0.05] px-3 py-2.5"
                  >
                    <div class="flex items-center justify-between gap-2">
                      <span class="text-xs font-medium text-warning">{approval.action}</span>
                      <span class="font-mono text-[10px] uppercase tracking-wider text-warning">{approval.status}</span>
                    </div>
                    <p class="mt-1 text-[11px] leading-5 text-muted">{approval.reason}</p>
                    <div :if={approval.status == "pending"} class="mt-2 flex items-center gap-2">
                      <button
                        id={"approve-run-action-#{approval.id}"}
                        type="button"
                        phx-click="decide_run_approval"
                        phx-value-id={approval.id}
                        phx-value-decision="approved"
                        class="mission-agent-button border border-success/30 bg-success/[0.08] px-2 py-1 font-mono text-[10px] font-semibold uppercase tracking-wider text-success hover:bg-success/15"
                      >
                        Approve
                      </button>
                      <button
                        id={"deny-run-action-#{approval.id}"}
                        type="button"
                        phx-click="decide_run_approval"
                        phx-value-id={approval.id}
                        phx-value-decision="denied"
                        class="mission-agent-button border border-danger/30 bg-danger/[0.08] px-2 py-1 font-mono text-[10px] font-semibold uppercase tracking-wider text-danger hover:bg-danger/15"
                      >
                        Deny
                      </button>
                    </div>
                  </div>
                </div>
              </div>

              <div class="mission-activity-column min-w-0">
                <div class="mb-4 flex items-center justify-between">
                  <div>
                    <h4 class="text-sm font-semibold tracking-tight text-content">
                      Event journal
                    </h4>
                    <p class="mt-1 text-[11px] text-subtle">
                      Run activity in recorded order
                    </p>
                  </div>
                  <span class="font-mono text-[11px] text-subtle">
                    cursor {@selected_run.event_sequence || 0}
                  </span>
                </div>

                <div
                  id="async-run-events"
                  role="log"
                  aria-live="polite"
                  aria-relevant="additions"
                  aria-atomic="false"
                  class="max-h-[24rem] space-y-0 overflow-y-auto pr-1"
                >
                  <div
                    :if={@events == []}
                    id="async-run-events-empty"
                    class="rounded-xl border border-dashed border-line px-3 py-8 text-center text-xs text-subtle"
                  >
                    Waiting for the first persisted event.
                  </div>
                  <article
                    :for={event <- @events}
                    id={"run-event-#{event.id}"}
                    class="group grid grid-cols-[2.5rem_minmax(0,1fr)] border-b border-line py-3 last:border-0"
                  >
                    <div class="font-mono text-[11px] tabular-nums text-subtle">
                      {event.sequence |> Integer.to_string() |> String.pad_leading(3, "0")}
                    </div>
                    <div class="min-w-0">
                      <div class="flex items-center justify-between gap-3">
                        <p class="truncate font-mono text-[11px] font-medium text-muted">
                          {event.type}
                        </p>
                        <span class="shrink-0 font-mono text-[10px] text-subtle">{event.source}</span>
                      </div>
                      <p class="mt-1 text-[11px] leading-5 text-subtle">
                        {event_summary(event)}
                      </p>
                    </div>
                  </article>
                </div>

                <div
                  :if={@artifacts != []}
                  id="async-run-artifacts"
                  class="mt-5 border-t border-line pt-4"
                >
                  <div class="mb-3 flex items-center justify-between gap-3">
                    <h4 class="text-sm font-semibold tracking-tight text-content">
                      Evidence & artifacts
                    </h4>
                    <span class="font-mono text-[11px] text-subtle">{length(@artifacts)} saved</span>
                  </div>
                  <div class="space-y-2">
                    <article
                      :for={artifact <- @artifacts}
                      id={"async-run-artifact-#{artifact.id}"}
                      class="rounded-xl border border-line bg-surface p-3"
                    >
                      <div class="flex items-start justify-between gap-3">
                        <div class="flex min-w-0 items-center gap-2">
                          <span class="flex h-6 w-6 shrink-0 items-center justify-center border border-accent/20 bg-accent/[0.05]">
                            <.icon name="hero-paper-clip" class="h-3 w-3 text-accent" />
                          </span>
                          <div class="min-w-0">
                            <p class="truncate text-[11px] font-medium text-muted">
                              {artifact.name}
                            </p>
                            <p class="mt-0.5 font-mono text-[10px] uppercase tracking-wider text-subtle">
                              {artifact.kind}
                            </p>
                          </div>
                        </div>
                        <span
                          :if={artifact_provider(artifact)}
                          class="shrink-0 border border-accent/20 bg-accent/[0.05] px-1.5 py-0.5 font-mono text-[10px] text-accent"
                        >
                          {artifact_provider(artifact)}
                        </span>
                      </div>

                      <p
                        :if={artifact_preview(artifact)}
                        id={"async-run-artifact-preview-#{artifact.id}"}
                        class="mt-3 line-clamp-5 border-l border-accent/30 pl-3 text-[11px] leading-5 text-muted"
                      >
                        {artifact_preview(artifact)}
                      </p>

                      <details
                        :if={artifact_content(artifact)}
                        id={"async-run-artifact-detail-#{artifact.id}"}
                        class="mt-3 overflow-hidden rounded-xl border border-line bg-inset"
                      >
                        <summary class="cursor-pointer px-3 py-2 font-mono text-[10px] font-semibold uppercase tracking-wider text-accent">
                          Open full artifact
                        </summary>
                        <pre class="max-h-96 overflow-auto whitespace-pre-wrap border-t border-line p-3 font-mono text-[11px] leading-5 text-muted">{artifact_content(artifact)}</pre>
                      </details>

                      <div
                        :if={artifact_sources(artifact) != []}
                        id={"async-run-artifact-sources-#{artifact.id}"}
                        class="mt-3 border-t border-line pt-2"
                      >
                        <p class="mb-1.5 text-[10px] font-semibold uppercase tracking-wider text-subtle">
                          Sources
                        </p>
                        <div class="flex flex-wrap gap-1.5">
                          <a
                            :for={{source, index} <- Enum.with_index(artifact_sources(artifact))}
                            id={"async-run-artifact-source-#{artifact.id}-#{index}"}
                            href={source_url(source)}
                            target="_blank"
                            rel="noopener noreferrer"
                            class="max-w-full truncate rounded-full border border-line bg-surface px-2 py-1 font-mono text-[10px] text-muted"
                          >
                            {source_label(source)}
                          </a>
                        </div>
                      </div>
                    </article>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :run, :any, required: true
  attr :agents, :any, required: true
  attr :agent_count, :integer, required: true
  attr :summary, :map, required: true
  attr :loading, :boolean, default: false
  attr :guidance, :map, default: %{}
  attr :receipts, :map, default: %{}

  def agent_fleet(assigns) do
    ~H"""
    <section
      id="run-agent-fleet"
      aria-labelledby="run-agent-fleet-heading"
      aria-busy={to_string(@loading)}
      data-fleet-state={fleet_state(@run, @agent_count, @summary, @loading)}
      class="mission-agent-fleet"
    >
      <header class="mission-fleet-heading">
        <div class="min-w-0">
          <h4 id="run-agent-fleet-heading" class="text-sm font-semibold tracking-tight text-content">
            Agent fleet
          </h4>
          <p class="mt-1 max-w-2xl text-[11px] leading-5 text-subtle">
            Workers assigned to this run. Manage each agent individually.
          </p>
        </div>

        <div
          id="run-agent-fleet-summary"
          role="status"
          aria-live="polite"
          aria-atomic="true"
          class="mission-fleet-summary"
        >
          <.fleet_fact label="Agents" value={@agent_count} tone="text-content" />
          <.fleet_fact label="Active" value={Map.get(@summary, :active, 0)} tone="text-success" />
          <.fleet_fact label="Paused" value={Map.get(@summary, :paused, 0)} tone="text-warning" />
          <.fleet_fact
            label="Attention"
            value={Map.get(@summary, :attention, 0)}
            tone="text-danger"
          />
        </div>
      </header>

      <div
        :if={Map.get(@summary, :recovering, 0) > 0}
        id="run-agent-fleet-recovering"
        role="status"
        class="flex items-start gap-2.5 border-b border-warning/20 bg-warning/[0.04] px-4 py-3 text-[11px] leading-5 text-warning"
      >
        <.icon name="hero-arrow-path" class="mt-0.5 h-3.5 w-3.5 shrink-0 animate-spin text-warning" />
        <span>
          {Map.get(@summary, :recovering, 0)} worker {pluralize(
            Map.get(@summary, :recovering, 0),
            "is",
            "are"
          )} reconciling durable state. Commands remain recorded while ownership is restored.
        </span>
      </div>

      <div
        :if={@loading}
        id="run-agent-fleet-loading"
        role="status"
        class="mission-fleet-list"
      >
        <div
          :for={index <- 1..2}
          id={"run-agent-fleet-skeleton-#{index}"}
          class="animate-pulse bg-surface p-4 sm:p-5"
        >
          <div class="h-3 w-28 bg-raised"></div>
          <div class="mt-4 h-2 w-4/5 bg-raised"></div>
          <div class="mt-2 h-2 w-2/3 bg-raised"></div>
          <div class="mt-5 h-px bg-raised"></div>
        </div>
      </div>

      <div
        :if={!@loading}
        id="run-agent-fleet-list"
        phx-update="stream"
        class="mission-fleet-list"
      >
        <div
          id="run-agent-fleet-empty"
          class="mission-fleet-empty hidden only:flex"
        >
          <div class="mission-empty-icon">
            <.icon name="hero-cpu-chip" class="h-4 w-4" />
          </div>
          <div>
            <p class="text-xs font-medium text-content">{fleet_empty_title(@run)}</p>
            <p class="mt-1 max-w-xl text-[11px] leading-5 text-subtle">
              {fleet_empty_copy(@run)}
            </p>
          </div>
        </div>

        <article
          :for={{dom_id, agent} <- @agents}
          id={dom_id}
          data-agent-status={agent_value(agent, :status, "pending")}
          data-agent-health={agent_health(agent)}
          class="mission-agent-card group min-w-0"
        >
          <% receipt = latest_agent_receipt(@receipts, agent) %>
          <div class="flex items-start justify-between gap-3">
            <div class="flex min-w-0 items-start gap-3">
              <span class={[
                "mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-lg border",
                agent_health_tone(agent_health(agent), :surface)
              ]}>
                <.icon name={agent_role_icon(agent)} class="h-4 w-4" />
              </span>
              <div class="min-w-0">
                <p class="truncate text-xs font-semibold text-content">
                  {agent_display_name(agent)}
                </p>
                <div class="mt-1 flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 font-mono text-[10px] uppercase tracking-wider text-subtle">
                  <span>{agent_value(agent, :role, "worker")}</span>
                  <span class="text-subtle">/</span>
                  <span
                    class="max-w-40 truncate normal-case tracking-normal"
                    title={agent_value(agent, :key, "agent")}
                  >
                    {agent_value(agent, :key, "agent")}
                  </span>
                </div>
              </div>
            </div>

            <div class="flex shrink-0 flex-col items-end gap-1">
              <span class={[
                "rounded-md border px-1.5 py-0.5 text-[10px] font-medium",
                agent_status_tone(agent_value(agent, :status, "pending"))
              ]}>
                {agent_value(agent, :status, "pending")}
              </span>
              <span class={[
                "flex items-center gap-1 font-mono text-[10px] uppercase tracking-wider",
                agent_health_tone(agent_health(agent), :text)
              ]}>
                <span class={[
                  "h-1 w-1 rounded-full",
                  agent_health(agent) == "healthy" && "animate-pulse",
                  agent_health_tone(agent_health(agent), :dot)
                ]}></span>
                {agent_health(agent)}
              </span>
            </div>
          </div>

          <div class="mission-agent-task mt-3">
            <p class="font-mono text-[10px] uppercase tracking-[0.16em] text-subtle">Current task</p>
            <p class="mt-1 line-clamp-2 break-words text-[11px] leading-5 text-muted">
              {agent_task(agent)}
            </p>
          </div>

          <div class="mt-4">
            <div class="mb-1.5 flex items-center justify-between font-mono text-[10px] text-subtle">
              <span class="min-w-0 truncate pr-2" title={agent_model(agent)}>{agent_model(agent)}</span>
              <span class="tabular-nums text-muted">{agent_progress(agent)}%</span>
            </div>
            <div
              role="progressbar"
              aria-label={"#{agent_display_name(agent)} progress"}
              aria-valuemin="0"
              aria-valuemax="100"
              aria-valuenow={agent_progress(agent)}
              class="h-px bg-raised"
            >
              <div
                class={[
                  "h-px transition-[width] duration-300",
                  agent_value(agent, :status, "pending") == "failed" && "bg-danger",
                  agent_value(agent, :status, "pending") != "failed" && "bg-accent"
                ]}
                style={"width: #{agent_progress(agent)}%"}
              >
              </div>
            </div>
          </div>

          <div class="mission-agent-metrics">
            <.agent_metric label="Tokens" value={format_count(agent_tokens(agent))} />
            <.agent_metric
              label="Avg latency"
              value={agent_average_latency(agent)}
            />
            <.agent_metric
              label="Requests"
              value={format_count(agent_value(agent, :request_count, 0))}
            />
          </div>

          <div class="mt-3 flex flex-wrap items-center justify-between gap-2 font-mono text-[10px] text-subtle">
            <span title={agent_heartbeat_title(agent)}>
              Heartbeat · {agent_heartbeat_label(agent)}
            </span>
            <span :if={agent_desired_state_pending?(agent)} class="text-warning">
              Requested · {agent_value(agent, :desired_state)}
            </span>
            <span :if={!agent_desired_state_pending?(agent)}>
              Last · {agent_last_latency(agent)}
            </span>
          </div>

          <div
            :if={agent_value(agent, :error_message)}
            id={"run-agent-error-#{agent_value(agent, :id)}"}
            role="alert"
            class="mt-3 break-words border-l-2 border-danger pl-3 text-[11px] leading-5 text-danger"
          >
            {agent_value(agent, :error_message)}
          </div>

          <div
            :if={receipt}
            id={"run-agent-control-receipt-#{agent_value(agent, :id)}"}
            role="status"
            data-control-status={agent_receipt_value(receipt, :status, "pending")}
            data-control-result-status={agent_receipt_result_status(receipt)}
            class={[
              "mt-3 rounded-lg border px-3 py-2.5",
              agent_receipt_tone(receipt)
            ]}
          >
            <div class="flex items-start justify-between gap-3 font-mono text-[10px] uppercase tracking-wider">
              <span class="font-semibold">
                #{agent_receipt_value(receipt, :sequence, 0)} · {agent_receipt_value(
                  receipt,
                  :kind,
                  "control"
                )}
              </span>
              <span class="shrink-0">
                {agent_receipt_lifecycle(receipt)}
              </span>
            </div>
            <p class="mt-1 text-[11px] leading-5 text-muted">
              {agent_receipt_summary(receipt)}
            </p>
            <p
              class="mt-1 font-mono text-[10px] text-subtle"
              title={agent_receipt_timestamp_title(receipt)}
            >
              {agent_receipt_timestamp_label(receipt)}
            </p>
          </div>

          <div class="mt-4 border-t border-line pt-3">
            <div class="flex flex-wrap gap-1.5">
              <button
                :if={agent_value(agent, :status) in ["idle", "running"]}
                id={"pause-run-agent-#{agent_value(agent, :id)}"}
                type="button"
                phx-click="control_run_agent"
                phx-value-id={agent_value(agent, :id)}
                phx-value-action="pause"
                phx-disable-with="Pausing…"
                disabled={agent_control_pending?(@receipts, agent, "pause")}
                aria-label={"Pause #{agent_display_name(agent)}"}
                class="mission-agent-button min-h-9 flex-1 border border-warning/25 bg-warning/[0.05] px-2.5 font-mono text-[10px] font-semibold uppercase tracking-wider text-warning transition-colors hover:bg-warning/10 disabled:cursor-wait disabled:opacity-45 sm:flex-none"
              >
                Pause
              </button>
              <button
                :if={agent_value(agent, :status) == "paused"}
                id={"resume-run-agent-#{agent_value(agent, :id)}"}
                type="button"
                phx-click="control_run_agent"
                phx-value-id={agent_value(agent, :id)}
                phx-value-action="resume"
                phx-disable-with="Resuming…"
                disabled={agent_control_pending?(@receipts, agent, "resume")}
                aria-label={"Resume #{agent_display_name(agent)}"}
                class="mission-agent-button min-h-9 flex-1 border border-success/25 bg-success/[0.05] px-2.5 font-mono text-[10px] font-semibold uppercase tracking-wider text-success transition-colors hover:bg-success/10 disabled:cursor-wait disabled:opacity-45 sm:flex-none"
              >
                Resume
              </button>
              <button
                :if={agent_retryable?(agent)}
                id={"restart-run-agent-#{agent_value(agent, :id)}"}
                type="button"
                phx-click="control_run_agent"
                phx-value-id={agent_value(agent, :id)}
                phx-value-action="restart"
                phx-disable-with="Restarting…"
                disabled={agent_control_pending?(@receipts, agent, "restart")}
                aria-label={"Restart #{agent_display_name(agent)}"}
                class="mission-agent-button min-h-9 flex-1 border border-accent/25 bg-accent/[0.05] px-2.5 font-mono text-[10px] font-semibold uppercase tracking-wider text-accent transition-colors hover:bg-accent/10 disabled:cursor-wait disabled:opacity-45 sm:flex-none"
              >
                Restart
              </button>
              <button
                :if={agent_cancellable?(agent)}
                id={"cancel-run-agent-#{agent_value(agent, :id)}"}
                type="button"
                phx-click="control_run_agent"
                phx-value-id={agent_value(agent, :id)}
                phx-value-action="cancel"
                phx-disable-with="Stopping…"
                disabled={agent_control_pending?(@receipts, agent, "cancel")}
                aria-label={"Stop #{agent_display_name(agent)}"}
                data-confirm="Stop only this agent? Dependent work may wait for recovery or operator action."
                class="mission-agent-button min-h-9 flex-1 border border-danger/25 bg-danger/[0.05] px-2.5 font-mono text-[10px] font-semibold uppercase tracking-wider text-danger transition-colors hover:bg-danger/10 disabled:cursor-wait disabled:opacity-45 sm:flex-none"
              >
                Stop
              </button>
            </div>

            <.form
              :if={agent_steerable?(agent)}
              for={agent_steering_form(agent, @guidance)}
              id={"run-agent-steering-form-#{agent_value(agent, :id)}"}
              phx-change="update_run_agent_guidance"
              phx-submit="steer_run_agent"
              class="mt-2 flex items-end gap-2"
            >
              <.input
                type="hidden"
                id={"run-agent-steering-agent-id-#{agent_value(agent, :id)}"}
                name="agent_id"
                value={agent_value(agent, :id)}
              />
              <div class="min-w-0 flex-1">
                <.input
                  field={agent_steering_form(agent, @guidance)[:guidance]}
                  id={"run-agent-steering-input-#{agent_value(agent, :id)}"}
                  type="text"
                  label="Agent guidance"
                  placeholder="Redirect this worker…"
                  class="mission-input block min-h-9 w-full border border-line bg-inset px-2.5 py-2 text-[11px] text-content outline-none transition-colors placeholder:text-subtle focus:border-accent/50"
                />
              </div>
              <button
                id={"run-agent-steering-submit-#{agent_value(agent, :id)}"}
                type="submit"
                phx-disable-with="Queueing…"
                disabled={agent_control_pending?(@receipts, agent, "steer")}
                aria-label={"Send guidance to #{agent_display_name(agent)}"}
                class="mission-button mission-button-primary mb-0.5 min-h-9 shrink-0 bg-accent px-3 font-mono text-[10px] font-semibold uppercase tracking-wider text-accent-ink transition-colors hover:bg-accent-strong disabled:cursor-wait disabled:bg-raised disabled:text-subtle"
              >
                Steer
              </button>
            </.form>
          </div>
        </article>
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :string, required: true

  defp fleet_fact(assigns) do
    ~H"""
    <div class="mission-fleet-fact">
      <span class={[@tone, "block text-xs font-semibold tabular-nums"]}>{@value}</span>
      <span class="mt-0.5 block text-[10px] text-subtle">{@label}</span>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp agent_metric(assigns) do
    ~H"""
    <div class="mission-agent-metric">
      <span class="block font-mono text-[10px] uppercase tracking-wider text-subtle">{@label}</span>
      <span class="mt-0.5 block truncate font-mono text-[11px] tabular-nums text-muted">{@value}</span>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp manifest_fact(assigns) do
    ~H"""
    <div class="min-w-0 bg-surface px-2.5 py-2">
      <p class="text-[10px] uppercase tracking-wider text-subtle">{@label}</p>
      <p class="mt-1 truncate font-mono text-[11px] text-muted" title={@value}>{@value}</p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :actual, :integer, required: true
  attr :limit, :integer, default: nil
  attr :unit, :string, required: true
  attr :limit_prefix, :string, default: "limit"

  defp budget_meter(assigns) do
    assigns =
      assigns
      |> assign(:percent, budget_percent(assigns.actual, assigns.limit))
      |> assign(:actual_label, budget_value(assigns.actual, assigns.unit))
      |> assign(:limit_label, budget_limit(assigns.limit, assigns.unit))

    ~H"""
    <div
      id={@id}
      data-budget-actual={@actual}
      data-budget-limit={@limit || "unset"}
      class="mission-budget-meter"
    >
      <div class="flex items-start justify-between gap-3">
        <div>
          <p class="text-[10px] font-semibold uppercase tracking-[0.14em] text-subtle">{@label}</p>
          <p class="mt-1 font-mono text-xs tabular-nums text-muted">{@actual_label}</p>
        </div>
        <span class="font-mono text-[10px] text-subtle">{@limit_prefix} {@limit_label}</span>
      </div>
      <div class="mt-2 h-1 overflow-hidden bg-raised">
        <div
          role="progressbar"
          aria-label={"#{@label} budget used"}
          aria-valuemin="0"
          aria-valuemax="100"
          aria-valuenow={@percent}
          class={[
            "h-full transition-[width] duration-300",
            @limit == nil && "bg-subtle",
            @limit != nil && @percent < 80 && "bg-accent",
            @limit != nil && @percent >= 80 && @percent < 100 && "bg-warning",
            @limit != nil && @percent >= 100 && "bg-danger"
          ]}
          style={"width: #{@percent}%"}
        >
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :string, required: true

  defp run_metric(assigns) do
    ~H"""
    <div class="mission-metric" data-tone={@tone} data-has-value={to_string(@value > 0)}>
      <div class="flex items-center gap-2">
        <span class={[
          "h-1.5 w-1.5 rounded-full",
          @tone == "emerald" && "bg-success",
          @tone == "blue" && "bg-info",
          @tone == "rose" && "bg-danger",
          @tone == "amber" && "bg-warning"
        ]}></span>
        <span class="mission-metric-label">{@label}</span>
      </div>
      <div class="mission-metric-value">{@value}</div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp run_fact(assigns) do
    ~H"""
    <div class="mission-run-fact">
      <div class="text-[10px] uppercase tracking-wider text-subtle">{@label}</div>
      <div class="mt-1 font-mono text-xs tabular-nums text-muted">{@value}</div>
    </div>
    """
  end

  attr :status, :string, required: true

  defp run_status(assigns) do
    ~H"""
    <span class={[
      "mission-run-status inline-flex items-center gap-1.5 text-[11px] font-medium",
      @status in ["running", "completed"] && "text-success",
      @status == "draft" && "text-accent",
      @status == "queued" && "text-info",
      @status in ["paused", "interrupted"] && "text-warning",
      @status in ["failed", "cancelled"] && "text-danger"
    ]}>
      <span class={[
        "h-1.5 w-1.5 rounded-full",
        @status == "running" && "animate-pulse bg-success",
        @status == "completed" && "bg-success",
        @status == "draft" && "bg-accent",
        @status == "queued" && "bg-info",
        @status in ["paused", "interrupted"] && "bg-warning",
        @status in ["failed", "cancelled"] && "bg-danger"
      ]}></span>
      {@status |> String.replace("_", " ")}
    </span>
    """
  end

  defp budget_percent(_actual, nil), do: 0
  defp budget_percent(_actual, limit) when not is_integer(limit) or limit <= 0, do: 0

  defp budget_percent(actual, limit) do
    actual
    |> Kernel.*(100)
    |> div(limit)
    |> min(100)
    |> max(0)
  end

  defp budget_limit(nil, _unit), do: "unset"
  defp budget_limit(value, unit), do: budget_value(value, unit)

  defp budget_value(value, "cost"), do: format_cost(value)

  defp budget_value(value, "time") do
    seconds = div(max(value || 0, 0), 1_000)

    cond do
      seconds >= 3_600 -> "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
      seconds >= 60 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{seconds}s"
    end
  end

  defp budget_value(value, _unit) when is_integer(value) do
    value
    |> Integer.to_string()
    |> add_digit_separators()
  end

  defp budget_value(_value, _unit), do: "0"

  defp add_digit_separators(value) do
    value
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp elapsed_ms(%{started_at: nil}), do: 0

  defp elapsed_ms(%{started_at: started_at} = run) do
    finished_at = Map.get(run, :completed_at) || DateTime.utc_now()
    max(DateTime.diff(finished_at, started_at, :millisecond), 0)
  end

  defp elapsed_ms(_run), do: 0

  defp manifest_enabled?(manifest) when map_size(manifest) == 0, do: false

  defp manifest_enabled?(manifest) do
    research = manifest_section(manifest)
    manifest_get(research, :enabled) != false and map_size(research) > 0
  end

  defp manifest_value(manifest, key, fallback) do
    research = manifest_section(manifest)

    flat_key =
      case key do
        :mode -> :research_mode
        :depth -> :research_depth
        _other -> key
      end

    value = manifest_get(research, key) || manifest_get(manifest, flat_key)

    display_value(value, fallback)
  end

  defp manifest_providers(manifest) do
    research = manifest_section(manifest)

    providers =
      manifest_get(research, :providers) || manifest_get(research, :provider) ||
        manifest_get(manifest, :research_providers)

    case providers do
      [] -> "Automatic"
      values when is_list(values) -> Enum.map_join(values, ", ", &display_value(&1, ""))
      value -> display_value(value, "Automatic")
    end
  end

  defp manifest_section(manifest) do
    case manifest_get(manifest, :research) do
      research when is_map(research) -> research
      _other -> manifest
    end
  end

  defp run_workspace_lock_state(nil, _locks), do: "none"

  defp run_workspace_lock_state(run, locks) do
    run_id = lock_value(run, :id)

    cond do
      Enum.any?(locks, fn lock ->
        lock_value(lock, :run_id) == run_id and lock_value(lock, :status) == "held"
      end) ->
        "held"

      Enum.any?(locks, fn lock ->
        lock_value(lock, :run_id) == run_id and lock_value(lock, :status) == "waiting"
      end) ->
        "waiting"

      true ->
        "none"
    end
  end

  defp selected_run_workspace_lock(nil, _locks, _state), do: nil

  defp selected_run_workspace_lock(run, locks, state) when state in ["held", "waiting"] do
    run_id = lock_value(run, :id)

    Enum.find(locks, fn lock ->
      lock_value(lock, :run_id) == run_id and lock_value(lock, :status) == state
    end)
  end

  defp selected_run_workspace_lock(_run, _locks, _state), do: nil

  defp selected_or_first(nil, locks), do: List.first(locks)
  defp selected_or_first(selected, _locks), do: selected

  defp workspace_lock_summary("free", _selected_state, _held, _waiting), do: "Available"

  defp workspace_lock_summary("held", "held", _held, _waiting),
    do: "Reserved by this run"

  defp workspace_lock_summary("waiting", "waiting", _held, _waiting),
    do: "This run is waiting"

  defp workspace_lock_summary("held", _selected_state, held, _waiting),
    do: "Reserved by #{workspace_lock_owner(held)}"

  defp workspace_lock_summary("waiting", _selected_state, _held, _waiting),
    do: "Waiting for workspace"

  defp workspace_lock_summary(_state, _selected_state, _held, _waiting), do: "Available"

  defp workspace_lock_context("free", _selected_state, _held, _waiting),
    do: "No active IexCode workspace reservations."

  defp workspace_lock_context("held", _selected_state, held, _waiting),
    do:
      "#{workspace_lock_resource(held)} · #{display_value(lock_value(held, :mode), "access")} access · #{workspace_lock_lease(held)}"

  defp workspace_lock_context("waiting", _selected_state, _held, waiting),
    do: "#{workspace_lock_resource(waiting)} · queued behind another workspace owner"

  defp workspace_lock_context(_state, _selected_state, _held, _waiting),
    do: "Workspace ownership is synchronized from the durable lock ledger."

  defp workspace_lock_resource(nil), do: "Workspace"

  defp workspace_lock_resource(lock) do
    resource_type = display_value(lock_value(lock, :resource_type), "workspace")
    resource_key = lock_value(lock, :resource_key)

    case {resource_type, resource_key} do
      {"project", _key} -> "Project workspace"
      {"git", _key} -> "Git repository"
      {"file", key} when is_binary(key) and key != "" -> "File · #{Path.basename(key)}"
      {type, _key} -> String.capitalize(type)
    end
  end

  defp workspace_lock_owner(nil), do: "another run"

  defp workspace_lock_owner(lock) do
    cond do
      is_binary(lock_value(lock, :run_id)) ->
        "Run ##{String.slice(lock_value(lock, :run_id), 0, 7)}"

      is_binary(lock_value(lock, :session_id)) ->
        "Session ##{String.slice(lock_value(lock, :session_id), 0, 7)}"

      true ->
        "workspace worker"
    end
  end

  defp workspace_lock_lease(lock) do
    case lock_value(lock, :status) do
      "held" ->
        case lock_value(lock, :lease_expires_at) do
          %DateTime{} = expires_at -> "lease until #{format_lock_time(expires_at)}"
          _ -> "active lease"
        end

      "waiting" ->
        case lock_value(lock, :wait_reason) do
          "queue_predecessor" -> "queued by request order"
          "batch_blocked" -> "waiting for lock batch"
          _ -> "waiting on owner release"
        end

      _ ->
        "inactive"
    end
  end

  defp workspace_lock_lease_title(lock) do
    case lock_value(lock, :lease_expires_at) do
      %DateTime{} = expires_at -> DateTime.to_iso8601(expires_at)
      _ -> workspace_lock_lease(lock)
    end
  end

  defp format_lock_time(%DateTime{} = datetime) do
    datetime
    |> DateTime.to_time()
    |> Time.truncate(:second)
    |> Time.to_string()
  end

  defp lock_value(nil, _key), do: nil

  defp lock_value(value, key) when is_map(value) do
    Map.get(value, key) || Map.get(value, Atom.to_string(key))
  end

  defp lock_value(_value, _key), do: nil

  defp manifest_get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp manifest_get(_value, _key), do: nil

  defp display_value(nil, fallback), do: fallback
  defp display_value("", fallback), do: fallback

  defp display_value(value, _fallback) when is_atom(value),
    do: value |> Atom.to_string() |> String.replace("_", " ")

  defp display_value(value, _fallback) when is_binary(value), do: String.replace(value, "_", " ")
  defp display_value(value, _fallback), do: to_string(value)

  defp fleet_state(_run, _count, _summary, true), do: "loading"
  defp fleet_state(_run, 0, _summary, false), do: "empty"

  defp fleet_state(_run, _count, summary, false) do
    cond do
      Map.get(summary, :recovering, 0) > 0 -> "recovering"
      Map.get(summary, :attention, 0) > 0 -> "attention"
      Map.get(summary, :active, 0) > 0 -> "active"
      Map.get(summary, :paused, 0) > 0 -> "paused"
      true -> "settled"
    end
  end

  defp fleet_empty_title(run) do
    case agent_value(run, :status) do
      "draft" -> "Draft has not started"
      "queued" -> "Fleet awaits dispatcher claim"
      "running" -> "No worker instances attached"
      _ -> "No persisted agent fleet"
    end
  end

  defp fleet_empty_copy(run) do
    case agent_value(run, :status) do
      "draft" ->
        "Start this draft when it is ready. No worker instances are created before it enters the queue."

      "queued" ->
        "Worker records appear only when the dispatcher materializes this run's topology."

      "running" ->
        "This run may be executing a non-agent step, or its durable topology has not materialized yet."

      status when status in ["completed", "failed", "cancelled", "interrupted"] ->
        "This archived run ended without a durable agent instance record."

      _ ->
        "This run has no agent workers attached. Tool-only and provider work can run without a fleet."
    end
  end

  defp agent_value(record, key, default \\ nil)
  defp agent_value(nil, _key, default), do: default

  defp agent_value(record, key, default) when is_map(record) do
    Map.get(record, key, Map.get(record, Atom.to_string(key), default))
  end

  defp agent_value(_record, _key, default), do: default

  defp agent_display_name(agent) do
    display_value(
      agent_value(agent, :display_name),
      agent_value(agent, :role, agent_value(agent, :key, "Agent worker"))
    )
  end

  defp agent_task(agent) do
    cond do
      present_value?(agent_value(agent, :current_task)) -> agent_value(agent, :current_task)
      agent_value(agent, :status) == "queued" -> "Waiting for a runnable step"
      agent_value(agent, :status) == "paused" -> "Paused with durable context retained"
      agent_value(agent, :status) in ["completed", "cancelled"] -> "No active task"
      true -> "No current task reported"
    end
  end

  defp agent_model(agent) do
    provider = agent_value(agent, :model_provider)
    model = agent_value(agent, :model_name)

    case {present_value?(provider), present_value?(model)} do
      {true, true} -> "#{provider} · #{model}"
      {false, true} -> to_string(model)
      {true, false} -> to_string(provider)
      _ -> "Model not reported"
    end
  end

  defp agent_progress(agent) do
    case agent_value(agent, :progress, 0) do
      value when is_integer(value) -> min(max(value, 0), 100)
      value when is_float(value) -> value |> round() |> min(100) |> max(0)
      _ -> 0
    end
  end

  defp agent_tokens(agent) do
    nonnegative_integer(agent_value(agent, :input_tokens)) +
      nonnegative_integer(agent_value(agent, :output_tokens))
  end

  defp nonnegative_integer(value) when is_integer(value), do: max(value, 0)
  defp nonnegative_integer(_value), do: 0

  defp format_count(value) when is_integer(value) and value >= 1_000_000,
    do: "#{Float.round(value / 1_000_000, 1)}m"

  defp format_count(value) when is_integer(value) and value >= 1_000,
    do: "#{Float.round(value / 1_000, 1)}k"

  defp format_count(value) when is_integer(value), do: Integer.to_string(max(value, 0))
  defp format_count(_value), do: "0"

  defp format_latency(value) when is_integer(value) and value >= 60_000,
    do: "#{Float.round(value / 60_000, 1)}m"

  defp format_latency(value) when is_integer(value) and value >= 1_000,
    do: "#{Float.round(value / 1_000, 1)}s"

  defp format_latency(value) when is_integer(value) and value >= 0, do: "#{value}ms"
  defp format_latency(_value), do: "—"

  defp agent_average_latency(agent) do
    if nonnegative_integer(agent_value(agent, :request_count)) > 0,
      do: format_latency(agent_value(agent, :average_latency_ms)),
      else: "—"
  end

  defp agent_last_latency(agent) do
    if nonnegative_integer(agent_value(agent, :request_count)) > 0,
      do: format_latency(agent_value(agent, :last_latency_ms)),
      else: "—"
  end

  defp agent_health(agent) do
    status = agent_value(agent, :status, "pending")

    cond do
      status in ["starting", "recovering"] -> "recovering"
      status == "failed" -> "degraded"
      status in ["completed", "cancelled", "interrupted"] -> "offline"
      status in ["pending", "queued"] -> "unknown"
      timestamp_past?(agent_value(agent, :lease_expires_at)) -> "stale"
      present_value?(agent_value(agent, :heartbeat_at)) -> "healthy"
      true -> "unknown"
    end
  end

  defp timestamp_past?(%DateTime{} = timestamp),
    do: DateTime.compare(timestamp, DateTime.utc_now()) == :lt

  defp timestamp_past?(%NaiveDateTime{} = timestamp) do
    timestamp
    |> DateTime.from_naive!("Etc/UTC")
    |> timestamp_past?()
  end

  defp timestamp_past?(_timestamp), do: false

  defp agent_heartbeat_label(agent) do
    case agent_value(agent, :heartbeat_at) || agent_value(agent, :last_active_at) do
      %DateTime{} = timestamp ->
        relative_time(timestamp)

      %NaiveDateTime{} = timestamp ->
        timestamp |> DateTime.from_naive!("Etc/UTC") |> relative_time()

      _ ->
        "not reported"
    end
  end

  defp agent_heartbeat_title(agent) do
    case agent_value(agent, :heartbeat_at) || agent_value(agent, :last_active_at) do
      %DateTime{} = timestamp -> DateTime.to_iso8601(timestamp)
      %NaiveDateTime{} = timestamp -> NaiveDateTime.to_iso8601(timestamp)
      _ -> "No heartbeat has been persisted"
    end
  end

  defp relative_time(%DateTime{} = timestamp) do
    seconds = max(DateTime.diff(DateTime.utc_now(), timestamp, :second), 0)

    cond do
      seconds < 5 -> "now"
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      true -> "#{div(seconds, 3_600)}h ago"
    end
  end

  defp agent_status_tone(status) do
    cond do
      status in ["running", "completed"] ->
        "border-success/20 bg-success/[0.06] text-success"

      status in ["paused", "waiting", "starting", "recovering"] ->
        "border-warning/25 bg-warning/[0.06] text-warning"

      status in ["failed", "cancelled", "interrupted"] ->
        "border-danger/20 bg-danger/[0.05] text-danger"

      true ->
        "border-line bg-raised text-muted"
    end
  end

  defp agent_health_tone("healthy", :surface),
    do: "border-success/20 bg-success/[0.05] text-success"

  defp agent_health_tone("healthy", :text), do: "text-success"
  defp agent_health_tone("healthy", :dot), do: "bg-success"

  defp agent_health_tone(health, :surface) when health in ["stale", "recovering"],
    do: "border-warning/25 bg-warning/[0.05] text-warning"

  defp agent_health_tone(health, :text) when health in ["stale", "recovering"],
    do: "text-warning"

  defp agent_health_tone(health, :dot) when health in ["stale", "recovering"],
    do: "bg-warning"

  defp agent_health_tone(health, :surface) when health in ["degraded", "offline"],
    do: "border-danger/20 bg-danger/[0.04] text-danger"

  defp agent_health_tone(health, :text) when health in ["degraded", "offline"],
    do: "text-danger"

  defp agent_health_tone(health, :dot) when health in ["degraded", "offline"],
    do: "bg-danger"

  defp agent_health_tone(_health, :surface),
    do: "border-line bg-raised text-subtle"

  defp agent_health_tone(_health, :text), do: "text-subtle"
  defp agent_health_tone(_health, :dot), do: "bg-subtle"

  defp agent_role_icon(agent) do
    case agent_value(agent, :role, "") |> to_string() |> String.downcase() do
      "planner" -> "hero-map"
      "explorer" -> "hero-magnifying-glass"
      "coder" -> "hero-code-bracket"
      "verifier" -> "hero-check-badge"
      "researcher" -> "hero-globe-alt"
      _ -> "hero-cpu-chip"
    end
  end

  defp agent_cancellable?(agent),
    do:
      agent_value(agent, :status) in [
        "pending",
        "starting",
        "idle",
        "running",
        "paused",
        "stopping"
      ]

  defp agent_retryable?(agent) do
    agent_value(agent, :status) == "interrupted" and
      nonnegative_integer(agent_value(agent, :attempt)) <
        max(nonnegative_integer(agent_value(agent, :max_attempts)), 1)
  end

  defp agent_steerable?(agent),
    do: agent_value(agent, :status) in ["idle", "running", "paused"]

  defp agent_desired_state_pending?(agent) do
    desired = agent_value(agent, :desired_state)
    status = agent_value(agent, :status)

    case desired do
      "paused" -> status != "paused"
      "stopped" -> status not in ["stopping", "completed", "failed", "cancelled"]
      "active" -> status in ["paused", "stopping", "failed", "cancelled", "interrupted"]
      _ -> false
    end
  end

  defp agent_steering_form(agent, guidance) do
    value = Map.get(guidance, agent_value(agent, :id), "")
    to_form(%{"guidance" => value}, as: :agent_control)
  end

  defp latest_agent_receipt(receipts, agent) when is_map(receipts) do
    receipts
    |> Map.get(agent_value(agent, :id), [])
    |> List.first()
  end

  defp latest_agent_receipt(_receipts, _agent), do: nil

  defp agent_control_pending?(receipts, agent, kind) do
    receipts
    |> Map.get(agent_value(agent, :id), [])
    |> Enum.any?(fn receipt ->
      agent_receipt_value(receipt, :kind, nil) == kind and
        agent_receipt_value(receipt, :status, nil) in ["pending", "claimed"]
    end)
  end

  defp agent_receipt_lifecycle(receipt) do
    case {agent_receipt_value(receipt, :status, "pending"), agent_receipt_result_status(receipt)} do
      {"applied", result_status} when result_status in ["queued", "consumed"] -> result_status
      {status, _result_status} -> status
    end
  end

  defp agent_receipt_result_status(receipt) do
    status =
      receipt
      |> agent_receipt_value(:result, %{})
      |> agent_receipt_map_value(:status)
      |> safe_agent_receipt_value()

    if status in ~w(queued consumed applied completed paused resumed stopped cancelled restarted steered),
      do: status,
      else: nil
  end

  defp agent_receipt_summary(receipt) do
    status = agent_receipt_value(receipt, :status, "pending")
    kind = agent_receipt_value(receipt, :kind, "control")
    result = agent_receipt_value(receipt, :result, %{})
    result_status = agent_receipt_result_status(receipt)
    error = result |> agent_receipt_map_value(:error) |> safe_agent_receipt_error()

    case {status, kind, result_status, error} do
      {"pending", _kind, _result_status, _error} ->
        "Persisted and waiting for the worker lease."

      {"claimed", _kind, _result_status, _error} ->
        "Claimed by the current worker generation."

      {"applied", "steer", "queued", _error} ->
        "Guidance is durable and waiting for worker consumption."

      {"applied", "steer", "consumed", _error} ->
        "Guidance was consumed by the worker."

      {"applied", _kind, result_status, _error} when is_binary(result_status) ->
        "Worker reported #{String.replace(result_status, "_", " ")}."

      {"applied", _kind, _result_status, _error} ->
        "The worker applied this control."

      {"rejected", _kind, _result_status, error} when is_binary(error) ->
        "Rejected · #{String.slice(error, 0, 180)}"

      {"rejected", _kind, _result_status, _error} ->
        "The worker rejected this control."

      {"superseded", _kind, _result_status, _error} ->
        "Replaced by a newer control or worker generation."

      {_status, _kind, _result_status, _error} ->
        "Recorded in the durable agent control log."
    end
  end

  defp agent_receipt_tone(receipt) do
    case {agent_receipt_value(receipt, :status, "pending"), agent_receipt_result_status(receipt)} do
      {"applied", "queued"} ->
        "border-info/20 bg-info/[0.04] text-info"

      {"applied", _result_status} ->
        "border-success/20 bg-success/[0.04] text-success"

      {status, _result_status} when status in ["rejected"] ->
        "border-danger/20 bg-danger/[0.04] text-danger"

      {"superseded", _result_status} ->
        "border-line bg-raised text-muted"

      {_status, _result_status} ->
        "border-warning/20 bg-warning/[0.04] text-warning"
    end
  end

  defp agent_receipt_timestamp_label(receipt) do
    requested =
      receipt_timestamp_part("Requested", agent_receipt_value(receipt, :inserted_at, nil))

    lifecycle =
      cond do
        agent_receipt_value(receipt, :resolved_at, nil) ->
          receipt_timestamp_part("Resolved", agent_receipt_value(receipt, :resolved_at, nil))

        agent_receipt_value(receipt, :claimed_at, nil) ->
          receipt_timestamp_part("Claimed", agent_receipt_value(receipt, :claimed_at, nil))

        true ->
          nil
      end

    [requested, lifecycle]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp agent_receipt_timestamp_title(receipt) do
    [
      receipt_timestamp_title_part("Requested", agent_receipt_value(receipt, :inserted_at, nil)),
      receipt_timestamp_title_part("Claimed", agent_receipt_value(receipt, :claimed_at, nil)),
      receipt_timestamp_title_part("Resolved", agent_receipt_value(receipt, :resolved_at, nil))
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "No control timestamp has been persisted"
      parts -> Enum.join(parts, " · ")
    end
  end

  defp receipt_timestamp_part(prefix, %DateTime{} = value),
    do: "#{prefix} #{relative_time(value)}"

  defp receipt_timestamp_part(prefix, %NaiveDateTime{} = value),
    do: "#{prefix} #{value |> DateTime.from_naive!("Etc/UTC") |> relative_time()}"

  defp receipt_timestamp_part("Requested", _value), do: "Requested time not reported"
  defp receipt_timestamp_part(_prefix, _value), do: nil

  defp receipt_timestamp_title_part(prefix, %DateTime{} = value),
    do: "#{prefix} #{DateTime.to_iso8601(value)}"

  defp receipt_timestamp_title_part(prefix, %NaiveDateTime{} = value),
    do: "#{prefix} #{NaiveDateTime.to_iso8601(value)}"

  defp receipt_timestamp_title_part(_prefix, _value), do: nil

  defp agent_receipt_value(nil, _key, fallback), do: fallback

  defp agent_receipt_value(receipt, key, fallback) when is_map(receipt) do
    Map.get(receipt, key, Map.get(receipt, Atom.to_string(key), fallback))
  end

  defp agent_receipt_value(_receipt, _key, fallback), do: fallback

  defp agent_receipt_map_value(value, key) when is_map(value) do
    Map.get(value, key) || Map.get(value, Atom.to_string(key))
  end

  defp agent_receipt_map_value(_value, _key), do: nil

  defp safe_agent_receipt_value(value) when is_binary(value), do: value
  defp safe_agent_receipt_value(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_agent_receipt_value(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_agent_receipt_value(_value), do: nil

  defp safe_agent_receipt_error(value) when is_atom(value), do: Atom.to_string(value)

  defp safe_agent_receipt_error(value) when is_binary(value) do
    if Regex.match?(~r/^[a-zA-Z0-9_.:-]{1,80}$/, value), do: value, else: "worker_error"
  end

  defp safe_agent_receipt_error(_value), do: nil

  defp present_value?(value), do: not is_nil(value) and value != ""

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_count, _singular, plural), do: plural

  defp control_value(control, key, fallback) do
    case manifest_get(control, key) do
      nil -> fallback
      value -> value
    end
  end

  defp control_fingerprint(control), do: :erlang.phash2(control)

  defp control_title(control) do
    control_value(control, :action, nil) ||
      control_value(control, :kind, nil) ||
      control_value(control, :type, nil) ||
      control_value(control, :tool_name, "Operator control")
      |> display_value("Operator control")
  end

  defp control_summary(control) do
    value =
      control_value(control, :instruction, nil) ||
        control_value(control, :message, nil) ||
        control_value(control, :reason, nil) ||
        control_value(control, :summary, nil) ||
        control_value(control, :output, nil)

    display_value(value, "Persisted in the run control journal.")
  end

  defp control_tone(status)
       when status in ["completed", "applied", "approved", :completed, :applied, :approved],
       do: "bg-success"

  defp control_tone(status)
       when status in [
              "failed",
              "denied",
              "rejected",
              "cancelled",
              :failed,
              :denied,
              :rejected,
              :cancelled
            ],
       do: "bg-danger"

  defp control_tone(status)
       when status in ["queued", "pending", "recorded", :queued, :pending, :recorded],
       do: "bg-info"

  defp control_tone(status) when status in ["superseded", :superseded], do: "bg-subtle"
  defp control_tone(_status), do: "bg-warning"

  defp artifact_provider(artifact) do
    metadata = Map.get(artifact, :metadata, %{}) || %{}
    provider = manifest_get(metadata, :provider) || manifest_get(metadata, :providers)

    case provider do
      providers when is_list(providers) -> Enum.map_join(providers, ", ", &display_value(&1, ""))
      value -> display_optional(value)
    end
  end

  defp artifact_preview(artifact) do
    metadata = Map.get(artifact, :metadata, %{}) || %{}

    [:report_preview, :preview, :excerpt, :summary, :report, :content]
    |> Enum.find_value(&manifest_get(metadata, &1))
    |> preview_content()
  end

  defp artifact_content(artifact) do
    metadata = Map.get(artifact, :metadata, %{}) || %{}

    case manifest_get(metadata, :content) do
      content when is_binary(content) and content != "" -> String.slice(content, 0, 250_000)
      _ -> nil
    end
  end

  defp artifact_sources(artifact) do
    metadata = Map.get(artifact, :metadata, %{}) || %{}
    decoded = decode_metadata_content(metadata)

    case manifest_get(metadata, :sources) || manifest_get(metadata, :source) ||
           manifest_get(decoded, :sources) do
      sources when is_list(sources) -> Enum.take(sources, 8)
      nil -> []
      source -> [source]
    end
  end

  defp decode_metadata_content(metadata) do
    case manifest_get(metadata, :content) do
      content when is_binary(content) ->
        case Jason.decode(content) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _other -> %{}
        end

      _other ->
        %{}
    end
  end

  defp preview_content(nil), do: nil

  defp preview_content(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, decoded} when is_map(decoded) ->
        manifest_get(decoded, :summary) ||
          case manifest_get(decoded, :sources) do
            sources when is_list(sources) ->
              "#{length(sources)} normalized research sources preserved."

            _other ->
              String.slice(content, 0, 1_200)
          end

      _other ->
        String.slice(content, 0, 1_200)
    end
  end

  defp preview_content(content), do: display_optional(content)

  defp source_label(source) when is_map(source) do
    manifest_get(source, :title) || manifest_get(source, :name) || manifest_get(source, :url) ||
      manifest_get(source, :uri) || "Recorded source"
  end

  defp source_label(source), do: display_value(source, "Recorded source")

  defp source_url(source) when is_map(source) do
    case manifest_get(source, :url) || manifest_get(source, :uri) do
      "https://" <> _ = url -> url
      "http://" <> _ = url -> url
      _ -> "#"
    end
  end

  defp source_url(_source), do: "#"

  defp display_optional(nil), do: nil
  defp display_optional(""), do: nil
  defp display_optional(value), do: display_value(value, "")

  defp event_summary(event) do
    payload = event.payload || %{}

    payload_value(payload, "message") ||
      status_transition(payload) ||
      payload_value(payload, "reason") ||
      payload_value(payload, "objective") ||
      "Persisted at #{format_time(event.occurred_at)}"
  end

  defp status_transition(payload) do
    from = payload_value(payload, "from")
    to = payload_value(payload, "to")
    if from && to, do: "#{from} → #{to}"
  end

  defp payload_value(payload, key) do
    atom_key =
      case key do
        "message" -> :message
        "reason" -> :reason
        "objective" -> :objective
        "from" -> :from
        "to" -> :to
      end

    Map.get(payload, key) || Map.get(payload, atom_key)
  end

  defp format_time(%DateTime{} = datetime) do
    datetime
    |> DateTime.to_time()
    |> Time.to_string()
  end

  defp format_time(_), do: "unknown time"

  defp format_cost(nil), do: "$0.00"

  defp format_cost(cents) when is_integer(cents) do
    dollars = div(cents, 100)
    remainder = cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "$#{dollars}.#{remainder}"
  end

  defp format_cost(_), do: "$0.00"
end

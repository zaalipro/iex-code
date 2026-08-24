defmodule IexCodeWeb.RunComponents do
  @moduledoc """
  UI primitives for the durable asynchronous run control plane.

  The component deliberately renders persisted run projections rather than
  process-local state. A LiveView can therefore reconnect and replay the same
  ordered journal after the browser or application shell has been closed.
  """

  use IexCodeWeb, :html

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

  def run_control_plane(assigns) do
    assigns = assign(assigns, :steering_form, to_form(%{"steering" => ""}))

    ~H"""
    <section id="async-run-control" aria-labelledby="async-run-heading" class="space-y-4">
      <div class="flex flex-col gap-4 border-b border-[#21262d] pb-5 lg:flex-row lg:items-end lg:justify-between">
        <div class="max-w-2xl">
          <div class="mb-2 flex items-center gap-2 text-[10px] font-mono font-semibold uppercase tracking-[0.22em] text-[#ff8a68]">
            <span class="h-1.5 w-1.5 bg-[#ff7e5f]"></span> Durable execution plane
          </div>
          <h2
            id="async-run-heading"
            class="text-2xl font-semibold tracking-[-0.035em] text-white md:text-3xl"
          >
            Work continues after you leave.
          </h2>
          <p class="mt-2 max-w-[65ch] text-sm leading-6 text-gray-400">
            Every background run, step transition, and journal event is committed before it is broadcast.
            Reconnect at any time and replay the ordered journal from SQLite.
          </p>
        </div>

        <div
          id="async-dispatcher-status"
          role="status"
          class={[
            "flex items-center gap-2 self-start rounded-lg border px-3 py-2 font-mono text-[11px] lg:self-auto",
            Map.get(@stats, :online, false) &&
              "border-emerald-500/20 bg-emerald-500/[0.06] text-emerald-300",
            !Map.get(@stats, :online, false) &&
              "border-rose-500/20 bg-rose-500/[0.06] text-rose-300"
          ]}
        >
          <span class={[
            "h-1.5 w-1.5 rounded-full",
            Map.get(@stats, :online, false) && "animate-pulse bg-emerald-400",
            !Map.get(@stats, :online, false) && "bg-rose-400"
          ]}></span>
          <%= if Map.get(@stats, :online, false) do %>
            Dispatcher online <span class="text-emerald-500/60">·</span>
            <span class="text-gray-400">{Map.get(@stats, :capacity, 0)} slots ready</span>
          <% else %>
            Dispatcher offline <span class="text-rose-500/60">·</span>
            <span class="text-gray-400">Run controls are unavailable</span>
          <% end %>
        </div>
      </div>

      <div
        id="async-run-metrics"
        role="status"
        aria-live="polite"
        aria-atomic="true"
        data-pending-approvals={Map.get(@run_counts, :approvals, 0)}
        class="grid grid-cols-2 border border-[#21262d] bg-[#0d1117] md:grid-cols-4"
      >
        <.run_metric label="Active now" value={Map.get(@run_counts, :active, 0)} tone="emerald" />
        <.run_metric label="Queued" value={Map.get(@run_counts, :queued, 0)} tone="blue" />
        <.run_metric label="Needs attention" value={Map.get(@run_counts, :attention, 0)} tone="rose" />
        <.run_metric label="Approvals" value={Map.get(@run_counts, :approvals, 0)} tone="amber" />
      </div>

      <div class="grid min-h-[25rem] overflow-hidden border border-[#21262d] bg-[#0d1117] xl:grid-cols-[21rem_minmax(0,1fr)]">
        <aside class="border-b border-[#21262d] xl:border-b-0 xl:border-r" aria-label="Run ledger">
          <div class="flex items-center justify-between border-b border-[#21262d] px-4 py-3">
            <div>
              <h3 class="text-sm font-semibold text-white">Run ledger</h3>
              <p class="mt-0.5 text-[10px] font-mono uppercase tracking-wider text-gray-500">
                Newest first · persisted
              </p>
            </div>
            <span class="font-mono text-xs tabular-nums text-gray-400">{@run_count}</span>
          </div>

          <div id="async-run-list" class="max-h-80 overflow-y-auto p-2 xl:max-h-[35rem]">
            <div :if={@runs == []} id="async-runs-empty" class="px-4 py-10 text-center">
              <div class="mx-auto mb-3 flex h-9 w-9 items-center justify-center border border-dashed border-[#38404a] text-gray-500">
                <.icon name="hero-queue-list" class="h-4 w-4" />
              </div>
              <p class="text-xs font-medium text-gray-300">No durable runs yet</p>
              <p class="mt-1 text-[11px] leading-5 text-gray-500">
                Choose <span class="font-mono text-gray-400">Background run</span> in the composer.
              </p>
            </div>

            <button
              :for={run <- @runs}
              id={"async-run-#{run.id}"}
              type="button"
              phx-click="select_async_run"
              phx-value-id={run.id}
              aria-pressed={@selected_run && @selected_run.id == run.id}
              class={[
                "group mb-1 w-full border px-3 py-3 text-left transition-colors",
                @selected_run && @selected_run.id == run.id &&
                  "border-[#4b5563] bg-[#1a2029]",
                (!@selected_run || @selected_run.id != run.id) &&
                  "border-transparent hover:border-[#30363d] hover:bg-[#141920]"
              ]}
            >
              <div class="mb-2 flex items-center justify-between gap-2">
                <.run_status status={run.status} />
                <span class="font-mono text-[10px] tabular-nums text-gray-600">
                  #{String.slice(run.id, 0, 7)}
                </span>
              </div>
              <p class="line-clamp-2 text-xs font-medium leading-5 text-gray-200">
                {run.objective}
              </p>
              <div class="mt-3 flex items-center justify-between font-mono text-[10px] text-gray-500">
                <span>{run.kind |> String.replace("_", " ")}</span>
                <span>attempt {run.attempt}/{run.max_attempts}</span>
              </div>
              <div class="mt-2 h-px overflow-hidden bg-[#252b34]">
                <div
                  role="progressbar"
                  aria-label={"#{run.objective} progress"}
                  aria-valuemin="0"
                  aria-valuemax="100"
                  aria-valuenow={min(max(run.progress || 0, 0), 100)}
                  class={[
                    "h-full transition-[width] duration-300",
                    run.status == "failed" && "bg-rose-500",
                    run.status == "interrupted" && "bg-amber-500",
                    run.status not in ["failed", "interrupted"] && "bg-emerald-400"
                  ]}
                  style={"width: #{min(max(run.progress || 0, 0), 100)}%"}
                >
                </div>
              </div>
            </button>
          </div>
        </aside>

        <div class="min-w-0">
          <div
            :if={is_nil(@selected_run)}
            class="flex min-h-80 items-center justify-center p-8 text-center"
          >
            <div>
              <.icon name="hero-cursor-arrow-rays" class="mx-auto h-6 w-6 text-gray-600" />
              <p class="mt-3 text-sm text-gray-400">Select a run to inspect its execution record.</p>
            </div>
          </div>

          <div :if={@selected_run} id="async-run-detail" class="min-w-0">
            <div class="border-b border-[#21262d] p-4 md:p-5">
              <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
                <div class="min-w-0 max-w-3xl">
                  <div class="mb-2 flex flex-wrap items-center gap-2">
                    <.run_status status={@selected_run.status} />
                    <span class="border border-[#30363d] px-2 py-0.5 font-mono text-[10px] uppercase tracking-wider text-gray-400">
                      {@selected_run.mode}
                    </span>
                    <span class="font-mono text-[10px] uppercase tracking-wider text-gray-500">
                      {@selected_run.priority} priority
                    </span>
                  </div>
                  <h3 class="text-lg font-semibold leading-7 tracking-tight text-white md:text-xl">
                    {@selected_run.objective}
                  </h3>
                  <p
                    :if={@selected_run.error_message}
                    class="mt-3 border-l-2 border-rose-500 pl-3 text-xs leading-5 text-rose-300"
                  >
                    {@selected_run.error_message}
                  </p>
                </div>

                <div id="async-run-actions" class="flex shrink-0 flex-wrap items-center gap-2">
                  <button
                    :if={@selected_run.status == "running"}
                    id="pause-async-run"
                    type="button"
                    phx-click="pause_async_run"
                    phx-value-id={@selected_run.id}
                    class="inline-flex items-center gap-1.5 border border-amber-500/30 bg-amber-500/[0.07] px-3 py-2 font-mono text-[11px] font-semibold text-amber-300 transition-colors hover:bg-amber-500/15"
                  >
                    <.icon name="hero-pause" class="h-3.5 w-3.5" /> Pause
                  </button>
                  <button
                    :if={@selected_run.status == "paused"}
                    id="resume-async-run"
                    type="button"
                    phx-click="resume_async_run"
                    phx-value-id={@selected_run.id}
                    class="inline-flex items-center gap-1.5 border border-emerald-500/30 bg-emerald-500/[0.07] px-3 py-2 font-mono text-[11px] font-semibold text-emerald-300 transition-colors hover:bg-emerald-500/15"
                  >
                    <.icon name="hero-play" class="h-3.5 w-3.5" /> Resume
                  </button>
                  <button
                    :if={@selected_run.status in ["queued", "running", "paused"]}
                    id="cancel-async-run"
                    type="button"
                    phx-click="cancel_async_run"
                    phx-value-id={@selected_run.id}
                    data-confirm="Cancel this run and roll back its scoped snapshots?"
                    class="inline-flex items-center gap-1.5 border border-rose-500/30 bg-rose-500/[0.07] px-3 py-2 font-mono text-[11px] font-semibold text-rose-300 transition-colors hover:bg-rose-500/15"
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
                    class="inline-flex items-center gap-1.5 bg-[#ff7e5f] px-3 py-2 font-mono text-[11px] font-semibold text-white transition-colors hover:bg-[#ff6b48]"
                  >
                    <.icon name="hero-arrow-path" class="h-3.5 w-3.5" /> Retry safely
                  </button>
                </div>
              </div>

              <div class="mt-5 grid gap-3 lg:grid-cols-[minmax(0,1fr)_minmax(18rem,0.72fr)]">
                <.form
                  for={@steering_form}
                  id="async-run-steering-form"
                  phx-submit="steer_async_run"
                  class="border border-[#29313a] bg-[#10151b] p-3"
                >
                  <.input
                    type="hidden"
                    id="async-run-steering-run-id"
                    name="run_id"
                    value={@selected_run.id}
                  />
                  <div class="mb-2 flex items-center justify-between gap-3">
                    <div>
                      <h4 class="text-[10px] font-semibold uppercase tracking-[0.16em] text-gray-300">
                        Live steering
                      </h4>
                      <p class="mt-0.5 text-[10px] text-gray-600">
                        Appended durably to this run's control log
                      </p>
                    </div>
                    <span class="font-mono text-[9px] text-gray-600">
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
                        class="block w-full border border-[#303844] bg-[#0b0f14] px-3 py-2 text-xs text-gray-100 outline-none transition-colors placeholder:text-gray-600 focus:border-cyan-500/60 disabled:cursor-not-allowed disabled:opacity-50"
                      />
                    </div>
                    <button
                      id="async-run-steering-submit"
                      type="submit"
                      disabled={@selected_run.status not in ["running", "paused"]}
                      class="mb-0.5 inline-flex h-9 shrink-0 items-center gap-1.5 bg-cyan-400 px-3 font-mono text-[10px] font-semibold uppercase tracking-wider text-[#071014] transition-colors hover:bg-cyan-300 disabled:cursor-not-allowed disabled:bg-gray-700 disabled:text-gray-500"
                    >
                      <.icon name="hero-arrow-up-right" class="h-3.5 w-3.5" /> Steer
                    </button>
                  </div>
                </.form>

                <div
                  :if={@selected_run.kind == "deep_research"}
                  id="async-run-research-manifest"
                  class="border border-[#29313a] bg-[#10151b] p-3"
                >
                  <div class="mb-3 flex items-center justify-between gap-3">
                    <div>
                      <h4 class="text-[10px] font-semibold uppercase tracking-[0.16em] text-gray-300">
                        Research manifest
                      </h4>
                      <p class="mt-0.5 text-[10px] text-gray-600">Committed execution intent</p>
                    </div>
                    <span class={[
                      "h-1.5 w-1.5 rounded-full",
                      manifest_enabled?(@run_manifest) && "bg-violet-400",
                      !manifest_enabled?(@run_manifest) && "bg-gray-700"
                    ]}></span>
                  </div>
                  <div class="grid grid-cols-3 gap-px bg-[#252c35]">
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

              <div
                id="async-run-budget-meters"
                class="mt-3 grid gap-px border border-[#21262d] bg-[#21262d] md:grid-cols-3"
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
                  label="Cost · reported only"
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

              <div class="mt-3 grid grid-cols-2 gap-px border border-[#21262d] bg-[#21262d] sm:grid-cols-4">
                <.run_fact label="Progress" value={"#{@selected_run.progress || 0}%"} />
                <.run_fact
                  label="Attempt"
                  value={"#{@selected_run.attempt}/#{@selected_run.max_attempts}"}
                />
                <.run_fact label="Events" value={to_string(@selected_run.event_sequence || 0)} />
                <.run_fact label="Cost" value={format_cost(@selected_run.cost_cents)} />
              </div>
            </div>

            <div class="grid min-w-0 lg:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)]">
              <div class="border-b border-[#21262d] p-4 md:p-5 lg:border-b-0 lg:border-r">
                <div class="mb-4 flex items-center justify-between">
                  <h4 class="text-xs font-semibold uppercase tracking-wider text-gray-300">
                    Execution graph
                  </h4>
                  <span class="font-mono text-[10px] text-gray-600">{length(@steps)} nodes</span>
                </div>

                <div id="async-run-steps" class="space-y-2">
                  <div
                    :if={@steps == []}
                    class="border border-dashed border-[#30363d] px-3 py-6 text-center text-xs text-gray-500"
                  >
                    Steps appear when the dispatcher claims this run.
                  </div>
                  <div
                    :for={step <- @steps}
                    id={"async-run-step-#{step.id}"}
                    class="relative border border-[#252c35] bg-[#11161d] px-3 py-3"
                  >
                    <div class="flex items-start gap-3">
                      <span class={[
                        "mt-1.5 h-2 w-2 shrink-0 rounded-full",
                        step.status == "completed" && "bg-emerald-400",
                        step.status == "running" && "animate-pulse bg-cyan-400",
                        step.status in ["failed", "cancelled"] && "bg-rose-400",
                        step.status in ["paused", "interrupted", "waiting_approval"] &&
                          "bg-amber-400",
                        step.status in ["pending", "ready", "blocked", "skipped"] && "bg-gray-600"
                      ]}></span>
                      <div class="min-w-0 flex-1">
                        <div class="flex items-center justify-between gap-3">
                          <p class="truncate text-xs font-medium text-gray-200">{step.title}</p>
                          <span class="font-mono text-[9px] uppercase tracking-wider text-gray-500">{step.status}</span>
                        </div>
                        <p
                          :if={step.depends_on != []}
                          class="mt-1 truncate font-mono text-[9px] text-gray-600"
                        >
                          waits for {Enum.join(step.depends_on, ", ")}
                        </p>
                        <div class="mt-2 h-px bg-[#272e37]">
                          <div
                            role="progressbar"
                            aria-label={"#{step.title} progress"}
                            aria-valuemin="0"
                            aria-valuemax="100"
                            aria-valuenow={min(max(step.progress || 0, 0), 100)}
                            class="h-full bg-cyan-400"
                            style={"width: #{min(max(step.progress || 0, 0), 100)}%"}
                          >
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>

                <div id="async-run-control-timeline" class="mt-5 border-t border-[#21262d] pt-4">
                  <div class="mb-3 flex items-center justify-between gap-3">
                    <div>
                      <h4 class="text-xs font-semibold uppercase tracking-wider text-gray-300">
                        Durable controls
                      </h4>
                      <p class="mt-1 text-[10px] text-gray-600">
                        Ordered operator interventions and lifecycle commands
                      </p>
                    </div>
                    <span class="font-mono text-[10px] tabular-nums text-gray-600">
                      {length(@controls)} entries
                    </span>
                  </div>
                  <div class="relative border-l border-[#303844] pl-4">
                    <div
                      :if={@controls == []}
                      id="async-run-controls-empty"
                      class="border border-dashed border-[#30363d] px-3 py-5 text-center text-xs text-gray-500"
                    >
                      No operator controls have been recorded.
                    </div>
                    <article
                      :for={control <- @controls}
                      id={"async-run-control-entry-#{control_value(control, :id, control_fingerprint(control))}"}
                      data-status={control_value(control, :status, "recorded")}
                      class="relative mb-2 border border-[#252c35] bg-[#11161d] px-3 py-3 last:mb-0"
                    >
                      <span class={[
                        "absolute -left-[1.28rem] top-4 h-2 w-2 rounded-full ring-4 ring-[#0d1117]",
                        control_tone(control_value(control, :status, "recorded"))
                      ]}></span>
                      <div class="flex items-start justify-between gap-3">
                        <div class="min-w-0">
                          <p class="truncate text-xs font-medium text-gray-200">
                            {control_title(control)}
                          </p>
                          <p class="mt-1 line-clamp-3 text-[11px] leading-5 text-gray-500">
                            {control_summary(control)}
                          </p>
                        </div>
                        <span class="shrink-0 font-mono text-[9px] uppercase tracking-wider text-gray-500">
                          {control_value(control, :status, "recorded")}
                        </span>
                      </div>
                    </article>
                  </div>
                </div>

                <div :if={@approvals != []} class="mt-5 border-t border-[#21262d] pt-4">
                  <h4 class="mb-3 text-xs font-semibold uppercase tracking-wider text-gray-300">
                    Approval gates
                  </h4>
                  <div
                    :for={approval <- @approvals}
                    id={"async-run-approval-#{approval.id}"}
                    class="mb-2 border border-amber-500/20 bg-amber-500/[0.05] px-3 py-2.5"
                  >
                    <div class="flex items-center justify-between gap-2">
                      <span class="text-xs font-medium text-amber-200">{approval.action}</span>
                      <span class="font-mono text-[9px] uppercase tracking-wider text-amber-400">{approval.status}</span>
                    </div>
                    <p class="mt-1 text-[11px] leading-5 text-gray-400">{approval.reason}</p>
                    <div :if={approval.status == "pending"} class="mt-2 flex items-center gap-2">
                      <button
                        id={"approve-run-action-#{approval.id}"}
                        type="button"
                        phx-click="decide_run_approval"
                        phx-value-id={approval.id}
                        phx-value-decision="approved"
                        class="border border-emerald-500/30 bg-emerald-500/[0.08] px-2 py-1 font-mono text-[9px] font-semibold uppercase tracking-wider text-emerald-300 hover:bg-emerald-500/15"
                      >
                        Approve
                      </button>
                      <button
                        id={"deny-run-action-#{approval.id}"}
                        type="button"
                        phx-click="decide_run_approval"
                        phx-value-id={approval.id}
                        phx-value-decision="denied"
                        class="border border-rose-500/30 bg-rose-500/[0.08] px-2 py-1 font-mono text-[9px] font-semibold uppercase tracking-wider text-rose-300 hover:bg-rose-500/15"
                      >
                        Deny
                      </button>
                    </div>
                  </div>
                </div>
              </div>

              <div class="min-w-0 p-4 md:p-5">
                <div class="mb-4 flex items-center justify-between">
                  <div>
                    <h4 class="text-xs font-semibold uppercase tracking-wider text-gray-300">
                      Event journal
                    </h4>
                    <p class="mt-1 text-[10px] text-gray-600">
                      Strict sequence order · reconnect-safe replay
                    </p>
                  </div>
                  <span class="font-mono text-[10px] text-gray-500">
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
                    class="border border-dashed border-[#30363d] px-3 py-8 text-center text-xs text-gray-500"
                  >
                    Waiting for the first persisted event.
                  </div>
                  <article
                    :for={event <- @events}
                    id={"run-event-#{event.id}"}
                    class="group grid grid-cols-[2.5rem_minmax(0,1fr)] border-b border-[#20262e] py-3 last:border-0"
                  >
                    <div class="font-mono text-[10px] tabular-nums text-gray-600">
                      {event.sequence |> Integer.to_string() |> String.pad_leading(3, "0")}
                    </div>
                    <div class="min-w-0">
                      <div class="flex items-center justify-between gap-3">
                        <p class="truncate font-mono text-[11px] font-medium text-gray-300">
                          {event.type}
                        </p>
                        <span class="shrink-0 font-mono text-[9px] text-gray-600">{event.source}</span>
                      </div>
                      <p class="mt-1 text-[11px] leading-5 text-gray-500">
                        {event_summary(event)}
                      </p>
                    </div>
                  </article>
                </div>

                <div
                  :if={@artifacts != []}
                  id="async-run-artifacts"
                  class="mt-5 border-t border-[#21262d] pt-4"
                >
                  <div class="mb-3 flex items-center justify-between gap-3">
                    <h4 class="text-xs font-semibold uppercase tracking-wider text-gray-300">
                      Evidence & artifacts
                    </h4>
                    <span class="font-mono text-[10px] text-gray-600">{length(@artifacts)} saved</span>
                  </div>
                  <div class="space-y-2">
                    <article
                      :for={artifact <- @artifacts}
                      id={"async-run-artifact-#{artifact.id}"}
                      class="border border-[#30363d] bg-[#11161d] p-3"
                    >
                      <div class="flex items-start justify-between gap-3">
                        <div class="flex min-w-0 items-center gap-2">
                          <span class="flex h-6 w-6 shrink-0 items-center justify-center border border-cyan-500/20 bg-cyan-500/[0.05]">
                            <.icon name="hero-paper-clip" class="h-3 w-3 text-cyan-400" />
                          </span>
                          <div class="min-w-0">
                            <p class="truncate text-[11px] font-medium text-gray-200">
                              {artifact.name}
                            </p>
                            <p class="mt-0.5 font-mono text-[9px] uppercase tracking-wider text-gray-600">
                              {artifact.kind}
                            </p>
                          </div>
                        </div>
                        <span
                          :if={artifact_provider(artifact)}
                          class="shrink-0 border border-violet-500/20 bg-violet-500/[0.05] px-1.5 py-0.5 font-mono text-[9px] text-violet-300"
                        >
                          {artifact_provider(artifact)}
                        </span>
                      </div>

                      <p
                        :if={artifact_preview(artifact)}
                        id={"async-run-artifact-preview-#{artifact.id}"}
                        class="mt-3 line-clamp-5 border-l border-cyan-500/30 pl-3 text-[11px] leading-5 text-gray-400"
                      >
                        {artifact_preview(artifact)}
                      </p>

                      <details
                        :if={artifact_content(artifact)}
                        id={"async-run-artifact-detail-#{artifact.id}"}
                        class="mt-3 border border-[#29313a] bg-[#0b0f14]"
                      >
                        <summary class="cursor-pointer px-3 py-2 font-mono text-[9px] font-semibold uppercase tracking-wider text-cyan-300">
                          Open full artifact
                        </summary>
                        <pre class="max-h-96 overflow-auto whitespace-pre-wrap border-t border-[#29313a] p-3 font-mono text-[10px] leading-5 text-gray-300">{artifact_content(artifact)}</pre>
                      </details>

                      <div
                        :if={artifact_sources(artifact) != []}
                        id={"async-run-artifact-sources-#{artifact.id}"}
                        class="mt-3 border-t border-[#252c35] pt-2"
                      >
                        <p class="mb-1.5 text-[9px] font-semibold uppercase tracking-wider text-gray-600">
                          Sources
                        </p>
                        <div class="flex flex-wrap gap-1.5">
                          <a
                            :for={{source, index} <- Enum.with_index(artifact_sources(artifact))}
                            id={"async-run-artifact-source-#{artifact.id}-#{index}"}
                            href={source_url(source)}
                            target="_blank"
                            rel="noopener noreferrer"
                            class="max-w-full truncate border border-[#2c3540] bg-[#0c1117] px-2 py-1 font-mono text-[9px] text-gray-400"
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

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp manifest_fact(assigns) do
    ~H"""
    <div class="min-w-0 bg-[#0c1117] px-2.5 py-2">
      <p class="text-[8px] uppercase tracking-wider text-gray-600">{@label}</p>
      <p class="mt-1 truncate font-mono text-[10px] text-gray-300" title={@value}>{@value}</p>
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
      class="bg-[#10151b] px-3 py-3"
    >
      <div class="flex items-start justify-between gap-3">
        <div>
          <p class="text-[9px] font-semibold uppercase tracking-[0.14em] text-gray-500">{@label}</p>
          <p class="mt-1 font-mono text-xs tabular-nums text-gray-200">{@actual_label}</p>
        </div>
        <span class="font-mono text-[9px] text-gray-600">{@limit_prefix} {@limit_label}</span>
      </div>
      <div class="mt-2 h-1 overflow-hidden bg-[#252c35]">
        <div
          role="progressbar"
          aria-label={"#{@label} budget used"}
          aria-valuemin="0"
          aria-valuemax="100"
          aria-valuenow={@percent}
          class={[
            "h-full transition-[width] duration-300",
            @limit == nil && "bg-gray-600",
            @limit != nil && @percent < 80 && "bg-cyan-400",
            @limit != nil && @percent >= 80 && @percent < 100 && "bg-amber-400",
            @limit != nil && @percent >= 100 && "bg-rose-400"
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
    <div class="border-b border-r border-[#21262d] px-4 py-3 last:border-r-0 md:border-b-0">
      <div class="flex items-center gap-2">
        <span class={[
          "h-1.5 w-1.5 rounded-full",
          @tone == "emerald" && "bg-emerald-400",
          @tone == "blue" && "bg-blue-400",
          @tone == "rose" && "bg-rose-400",
          @tone == "amber" && "bg-amber-400"
        ]}></span>
        <span class="text-[10px] uppercase tracking-wider text-gray-500">{@label}</span>
      </div>
      <div class="mt-1 font-mono text-xl font-medium tabular-nums text-gray-100">{@value}</div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp run_fact(assigns) do
    ~H"""
    <div class="bg-[#11161d] px-3 py-2.5">
      <div class="text-[9px] uppercase tracking-wider text-gray-600">{@label}</div>
      <div class="mt-1 font-mono text-xs tabular-nums text-gray-300">{@value}</div>
    </div>
    """
  end

  attr :status, :string, required: true

  defp run_status(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 font-mono text-[9px] font-semibold uppercase tracking-[0.14em]",
      @status in ["running", "completed"] && "text-emerald-400",
      @status == "queued" && "text-blue-400",
      @status in ["paused", "interrupted"] && "text-amber-400",
      @status in ["failed", "cancelled"] && "text-rose-400"
    ]}>
      <span class={[
        "h-1.5 w-1.5 rounded-full",
        @status == "running" && "animate-pulse bg-emerald-400",
        @status == "completed" && "bg-emerald-400",
        @status == "queued" && "bg-blue-400",
        @status in ["paused", "interrupted"] && "bg-amber-400",
        @status in ["failed", "cancelled"] && "bg-rose-400"
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
       do: "bg-emerald-400"

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
       do: "bg-rose-400"

  defp control_tone(status)
       when status in ["queued", "pending", "recorded", :queued, :pending, :recorded],
       do: "bg-blue-400"

  defp control_tone(status) when status in ["superseded", :superseded], do: "bg-gray-500"
  defp control_tone(_status), do: "bg-amber-400"

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

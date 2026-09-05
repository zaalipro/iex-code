defmodule IexCodeWeb.WorkspaceComponents do
  @moduledoc """
  Reusable Phoenix Function Components for the Next-Level IexCode Desktop UI.
  Implements Milestone 3 & 4 UI/UX, Inline Editor, Diff Hunk Management & Live Telemetry:
  - F5: Live Telemetry & 4-Column Subagent Cards (<.subagent_cards>)
  - F6: Hierarchical Operation Tree (<.operation_tree>, <.tree_node>)
  - F7: Interactive Diff Hunk Viewer (<.interactive_diff_viewer>, <.diff_viewer>)
  - F8: Interactive Inline Code Editor & File Explorer (<.file_explorer>)
  - F9: Terminal Session Integration & Runner (<.terminal_session>)
  - F10: Collapsible Reasoning / Thinking Trace (<.thinking_trace>)
  - F11: Markdown & Code Block Formatter (<.markdown_content>)
  """
  use Phoenix.Component
  import IexCodeWeb.CoreComponents
  import IexCodeWeb.PageHeaderComponents
  import Phoenix.HTML
  alias IexCode.Engine.OperationManager
  alias IexCode.Tools.Git.DiffParser

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :icon, :string, default: "hero-command-line"
  attr :class, :string, default: ""
  attr :loading, :boolean, default: false

  defp orbital_empty(assigns) do
    ~H"""
    <div id={@id} class={["orbital-empty", @class]} role="status" aria-busy={@loading}>
      <div class="orbital-reticle" aria-hidden="true">
        <span class="orbital-reticle-ring"></span>
        <span class="orbital-reticle-axis"></span>
        <div class="orbital-reticle-core">
          <.icon name={@icon} class={["h-5 w-5", @loading && "animate-pulse"]} />
        </div>
        <span class="orbital-reticle-point"></span>
      </div>
      <div class="orbital-empty-content">
        <h3>{@title}</h3>
        <p>{@description}</p>
      </div>
    </div>
    """
  end

  # ============================================================================
  # F5: Live Telemetry & 4-Column Subagent Cards
  # ============================================================================

  @doc """
  Renders legacy interactive-session role templates (Planner, Explorer, Coder, Verifier).
  A card becomes operation telemetry only when a matching operation exists; idle cards
  are templates and never claim to be live or persisted workers.
  """
  attr :operations, :list, default: []
  attr :active_stage, :atom, default: :init
  attr :active_agent, :string, default: nil
  attr :swarm_mode, :boolean, default: true

  def subagent_cards(assigns) do
    agents = [
      %{
        name: "PlannerAgent",
        key: :planner,
        title: "Planner",
        desc: "Architecture decomposition & milestone planning",
        icon: "hero-map"
      },
      %{
        name: "ExplorerAgent",
        key: :explorer,
        title: "Explorer",
        desc: "AST code discovery, file tree inspection, symbol lookups",
        icon: "hero-magnifying-glass"
      },
      %{
        name: "CoderAgent",
        key: :coder,
        title: "Coder",
        desc: "MultiPatch fuzzy patch formulation & atomic file generation",
        icon: "hero-code-bracket"
      },
      %{
        name: "VerifierAgent",
        key: :verifier,
        title: "Verifier",
        desc: "ExUnit test runner, compiler backtrace parser & AutoFix loop",
        icon: "hero-check-badge"
      }
    ]

    assigns = assign(assigns, :agents, agents)

    ~H"""
    <div
      id="subagent-cards-grid"
      class="orbital-role-grid grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-3"
    >
      <%= for agent <- @agents do %>
        <% op = latest_op_for_agent(@operations, agent.name)

        status =
          cond do
            is_nil(op) or is_nil(op.status) -> "idle"
            is_binary(op.status) -> op.status
            is_atom(op.status) -> Atom.to_string(op.status)
            true -> to_string(op.status)
          end

        normalized_status =
          case String.downcase(status) do
            "completed" -> "completed"
            "done" -> "completed"
            "failed" -> "failed"
            "error" -> "failed"
            "running" -> "running"
            _ -> "idle"
          end

        progress = if op && is_number(op.progress), do: min(max(op.progress, 0), 100), else: 0
        pid_str = if op && op.pid_str, do: op.pid_str, else: nil
        duration = if op && op.duration_ms, do: "#{op.duration_ms}ms", else: "--"
        current_msg = if op, do: op.result || op.title || agent.desc, else: agent.desc

        is_active =
          is_binary(@active_agent) and
            String.contains?(@active_agent, String.replace(agent.name, "Agent", ""))

        stage_label = @active_stage |> to_string() |> String.upcase()
        stage_failed = stage_label in ["FAILED", "ERROR"] %>
        <div
          id={"subagent-card-#{agent.key}"}
          class={[
            "orbital-role-card bg-surface border rounded-[20px] p-4 flex flex-col justify-between transition-smooth relative overflow-hidden",
            normalized_status == "running" && "border-accent/50",
            normalized_status != "running" && "border-line hover:border-line",
            is_active && "ring-1 ring-accent/40"
          ]}
        >
          <%!-- Active operation indicator --%>
          <%= if normalized_status == "running" do %>
            <div class={[
              "absolute top-0 left-0 right-0 h-0.5 bg-accent",
              "animate-pulse"
            ]}>
            </div>
          <% end %>

          <div>
            <%!-- Header --%>
            <div class="flex flex-wrap items-center justify-between gap-2 mb-3">
              <span
                title={agent.name}
                class="text-sm font-semibold text-content flex items-center gap-2"
              >
                <.icon name={agent.icon} class="w-4 h-4" />
                {agent.title}
              </span>
              <div class="flex items-center gap-1.5">
                <%= if pid_str do %>
                  <span
                    class="text-[10px] font-mono text-success bg-success/10 px-1.5 py-0.5 rounded border border-success/20 truncate max-w-[90px]"
                    title={pid_str}
                  >
                    {pid_str}
                  </span>
                <% else %>
                  <span title="OTP Supervised when active" class="text-[10px] text-subtle">
                    Role template
                  </span>
                <% end %>
                <span class={[
                  "text-[10px] font-mono px-1.5 py-0.5 rounded border font-semibold",
                  normalized_status == "running" &&
                    "text-warning bg-warning/10 border-warning/30 animate-pulse",
                  normalized_status == "completed" &&
                    "text-success bg-success/10 border-success/30",
                  normalized_status == "failed" && "text-danger bg-danger/10 border-danger/30",
                  normalized_status == "idle" && "text-muted bg-raised border-line"
                ]}>
                  {String.upcase(normalized_status)}
                </span>
              </div>
            </div>

            <%!-- Role & Activity --%>
            <p class="text-xs leading-5 text-muted mb-2 line-clamp-2">
              {current_msg}
            </p>

            <%!-- Active Stage / Agent indicator --%>
            <%= if is_active do %>
              <div class="flex items-center gap-1.5 mb-2">
                <span class={[
                  "text-[10px] font-mono px-1.5 py-0.5 rounded border font-semibold uppercase tracking-wider",
                  stage_failed && "text-danger bg-danger/10 border-danger/30",
                  not stage_failed && "text-accent bg-accent/10 border-accent/30"
                ]}>
                  Stage: {stage_label}
                </span>
                <span class="text-[10px] font-mono text-subtle">Active Agent</span>
              </div>
            <% end %>
          </div>

          <%!-- Progress & Latency Footer --%>
          <div class="pt-3 border-t border-line space-y-1.5">
            <div class="flex justify-between items-center text-[11px] font-mono text-muted">
              <span class="text-[10px] text-subtle">Latency:
              <strong class="text-muted">{duration}</strong></span>
              <span class={[
                "font-semibold",
                if(normalized_status == "completed", do: "text-success", else: "text-muted")
              ]}>
                {progress}%
              </span>
            </div>
            <div class="w-full bg-raised h-1.5 rounded-full overflow-hidden">
              <div
                class={[
                  "h-full rounded-full transition-[width] duration-300 ease-out",
                  normalized_status == "failed" && "bg-danger",
                  normalized_status == "completed" && "bg-success",
                  normalized_status not in ["failed", "completed"] && "bg-accent"
                ]}
                style={"width: #{progress}%"}
              >
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp latest_op_for_agent(operations, agent_name) do
    short_name = String.replace(agent_name, "Agent", "")

    Enum.find(operations, fn op ->
      op_agent = to_string(op.agent_name || "")
      op_agent == agent_name or String.contains?(op_agent, short_name)
    end)
  end

  # ============================================================================
  # F6: Hierarchical Operation Tree
  # ============================================================================

  @doc """
  Renders a visual nested parent-child operation tree using `parent_op_id` with CSS connector lines.
  Includes expand/collapse toggles, status badges, execution metrics, and error trace previews.
  """
  attr :operations, :list, default: []
  attr :expanded_ops, :any, default: %MapSet{}

  def operation_tree(assigns) do
    tree = OperationManager.build_tree(assigns.operations)
    stats = OperationManager.tree_stats(assigns.operations)
    assigns = assign(assigns, tree: tree, stats: stats)

    ~H"""
    <div
      id="operation-tree-root"
      class="orbital-panel orbital-operation-tree bg-surface border border-line rounded-[20px] p-5 space-y-4"
    >
      <%!-- Tree Header --%>
      <div class="flex items-center justify-between pb-3 border-b border-line">
        <div class="flex items-center gap-3">
          <h3 class="text-sm font-semibold text-content font-mono flex items-center gap-2">
            <.icon name="hero-list-bullet" class="w-4 h-4 text-success" /> Execution Hierarchy
            <span class="px-2 py-0.5 rounded-full bg-raised text-xs text-muted border border-line">
              {@stats.total} ops
            </span>
          </h3>
          <div class="hidden sm:flex items-center gap-2 text-[11px] font-mono text-muted">
            <span class="flex items-center gap-1"><span class="w-1.5 h-1.5 rounded-full bg-success"></span> {@stats.completed} done</span>
            <span class="flex items-center gap-1"><span class="w-1.5 h-1.5 rounded-full bg-warning animate-pulse"></span> {@stats.running} running</span>
            <%= if @stats.failed > 0 do %>
              <span class="flex items-center gap-1 text-danger"><span class="w-1.5 h-1.5 rounded-full bg-danger"></span> {@stats.failed} failed</span>
            <% end %>
          </div>
        </div>

        <button
          phx-click="clear_operations"
          class="text-xs font-mono text-subtle hover:text-danger transition-smooth flex items-center gap-1"
        >
          <.icon name="hero-trash" class="w-3.5 h-3.5" /> Clear Operations
        </button>
      </div>

      <%!-- Tree Nodes List --%>
      <%= if @tree == [] do %>
        <.orbital_empty
          id="operation-tree-empty"
          title="No operations yet"
          description="No operations recorded in this session. Activity will appear as agents work through your task."
          icon="hero-list-bullet"
          class="orbital-empty--compact"
        />
      <% else %>
        <div class="space-y-2 font-mono text-xs">
          <%= for root_op <- @tree do %>
            <.tree_node op={root_op} depth={0} expanded_ops={@expanded_ops} />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Recursive tree node component rendering an operation with status badge, latency, PID, and child operations.
  """
  attr :op, :map, required: true
  attr :depth, :integer, default: 0
  attr :expanded_ops, :any, default: %MapSet{}

  def tree_node(assigns) do
    has_children = length(assigns.op.children || []) > 0
    is_expanded = MapSet.member?(assigns.expanded_ops, assigns.op.id)
    assigns = assign(assigns, has_children: has_children, is_expanded: is_expanded)

    ~H"""
    <div class={["relative", @depth > 0 && "pl-6 tree-node-connector"]}>
      <div class={[
        "p-3 rounded-xl border transition-smooth",
        @op.status == "running" && "bg-raised border-warning/40 shadow-sm",
        @op.status == "failed" && "bg-danger/5 border-danger/40",
        @op.status != "running" && @op.status != "failed" &&
          "bg-raised border-line hover:border-accent/30"
      ]}>
        <%!-- Top Row: Status, Agent, Title, Metrics, Chevron --%>
        <div class="flex items-center justify-between gap-2">
          <div class="flex items-center gap-2.5 min-w-0 flex-1">
            <%!-- Expand / Collapse chevron if children exist --%>
            <%= if @has_children do %>
              <button
                phx-click="toggle_op_detail"
                phx-value-id={@op.id}
                class="text-muted hover:text-content transition-smooth"
              >
                <.icon
                  name={if(@is_expanded, do: "hero-chevron-down", else: "hero-chevron-right")}
                  class="w-3.5 h-3.5"
                />
              </button>
            <% else %>
              <span class="w-3.5"></span>
            <% end %>

            <%!-- Status Dot --%>
            <span class={[
              "w-2 h-2 rounded-full shrink-0",
              @op.status == "completed" && "bg-success",
              @op.status == "running" &&
                "bg-warning animate-pulse",
              @op.status == "failed" && "bg-danger",
              @op.status == "pending" && "bg-subtle"
            ]}></span>

            <%!-- Agent Tag --%>
            <span class="font-bold text-content shrink-0 text-xs">
              {@op.agent_name || "System"}
            </span>

            <%!-- Operation Type Badge --%>
            <span class="text-[10px] text-muted bg-inset border border-line px-1.5 py-0.5 rounded shrink-0">
              {@op.op_type}
            </span>

            <%!-- Title --%>
            <span class="text-muted truncate text-xs">
              {@op.title}
            </span>
          </div>

          <%!-- Right side metrics --%>
          <div class="flex items-center gap-3 text-[11px] text-muted shrink-0">
            <%= if @op.duration_ms do %>
              <span class="text-muted">{@op.duration_ms}ms</span>
            <% end %>
            <%= if @op.pid_str do %>
              <span class="text-success bg-success/10 px-1.5 py-0.5 rounded border border-success/20 text-[10px]">
                {@op.pid_str}
              </span>
            <% end %>
            <button
              phx-click="toggle_op_detail"
              phx-value-id={@op.id}
              class="text-muted hover:text-content p-1 rounded transition-smooth"
              title="Inspect Details"
            >
              <.icon name="hero-ellipsis-horizontal" class="w-3.5 h-3.5" />
            </button>
          </div>
        </div>

        <%!-- Detail Drawer (Parameters, Error, Result) --%>
        <%= if @is_expanded do %>
          <div class="mt-3 pt-3 border-t border-line space-y-2 text-[11px] font-mono animate-in fade-in">
            <%= if @op.error_message do %>
              <div class="p-2.5 rounded-lg bg-danger/10 border border-danger/30 text-danger whitespace-pre-wrap">
                <strong class="text-danger">Error:</strong> {@op.error_message}
              </div>
            <% end %>

            <%= if @op.result do %>
              <div class="p-2.5 rounded-lg bg-inset border border-line text-muted whitespace-pre-wrap max-h-48 overflow-y-auto">
                <strong class="text-muted block mb-1">Result:</strong>
                {@op.result}
              </div>
            <% end %>

            <%= if @op.params && @op.params != %{} do %>
              <div class="p-2 rounded bg-inset border border-line text-muted">
                <span class="text-subtle">Params:</span> {inspect(@op.params)}
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <%!-- Recursive Children Rendering --%>
      <%= if @has_children and @is_expanded do %>
        <div class="space-y-2 mt-2">
          <%= for child <- @op.children do %>
            <.tree_node op={child} depth={@depth + 1} expanded_ops={@expanded_ops} />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # F7: Interactive Code Diff Hunk Viewer (<.interactive_diff_viewer>, <.diff_viewer>)
  # ============================================================================

  @doc """
  Renders interactive side-by-side and inline code diff viewer with per-hunk action buttons:
  - "Accept Hunk" (`accept_hunk`), "Reject Hunk" (`reject_hunk`), "Revert Hunk" (`revert_hunk`)
  - "Revert File" (`revert_file`), "Accept All Hunks" (`accept_all_hunks`)
  """
  attr :id, :string, default: "diff-viewer-container"
  attr :diff_text, :string, default: ""
  attr :file_path, :string, default: nil
  attr :diff_mode, :string, default: "inline"
  attr :hunks, :list, default: nil
  attr :status, :any, default: :modified
  attr :additions, :integer, default: 0
  attr :deletions, :integer, default: 0
  attr :staged, :boolean, default: false
  attr :is_checkpoint, :boolean, default: false
  attr :rollback_tx_id, :string, default: nil
  attr :class, :string, default: "h-full"

  def diff_viewer(assigns), do: interactive_diff_viewer(assigns)

  def interactive_diff_viewer(assigns) do
    diff_text = assigns[:diff_text] || ""
    hunks = assigns[:hunks]
    status = assigns[:status] || :modified
    file_path = assigns[:file_path]
    diff_mode = assigns[:diff_mode] || "inline"
    id = assigns[:id] || "diff-viewer-container"
    staged = assigns[:staged] || false
    is_checkpoint = assigns[:is_checkpoint] || false
    rollback_tx_id = assigns[:rollback_tx_id]
    class_attr = assigns[:class] || "h-full"

    # Decompose diff_text into structured hunks if not explicitly passed
    resolved_hunks =
      cond do
        is_list(hunks) && hunks != [] ->
          hunks

        is_binary(diff_text) && String.trim(diff_text) != "" ->
          case DiffParser.parse(diff_text) do
            {:ok, [file_diff | _]} -> file_diff.hunks
            _ -> []
          end

        true ->
          []
      end

    assigns =
      assigns
      |> assign(:id, id)
      |> assign(:staged, staged)
      |> assign(:is_checkpoint, is_checkpoint)
      |> assign(:rollback_tx_id, rollback_tx_id)
      |> assign(:class, class_attr)
      |> assign(:diff_text, diff_text)
      |> assign(:status, status)
      |> assign(:file_path, file_path)
      |> assign(:diff_mode, diff_mode)
      |> assign(:resolved_hunks, resolved_hunks)

    ~H"""
    <div
      id={@id}
      class={[
        "orbital-panel orbital-diff min-h-0 min-w-0 bg-surface border border-line rounded-[20px] flex flex-col overflow-hidden",
        @class
      ]}
    >
      <%!-- Toolbar Header --%>
      <div class="diff-viewer-header p-3 border-b border-line bg-raised flex flex-wrap items-center justify-between gap-2 shrink-0 font-mono text-xs">
        <div class="flex min-w-0 flex-1 items-center gap-2">
          <.icon name="hero-code-bracket-square" class="w-4 h-4 text-accent shrink-0" />
          <span class="min-w-0 truncate font-semibold text-content">
            {@file_path || "Multi-File Patch Preview"}
          </span>
          <span class={[
            "px-2 py-0.5 rounded text-[10px] font-bold uppercase shrink-0",
            to_string(@status) in ["added", "untracked"] &&
              "bg-success/10 text-success border border-success/30",
            to_string(@status) == "deleted" &&
              "bg-danger/10 text-danger border border-danger/30",
            true && "bg-warning/10 text-warning border border-warning/30"
          ]}>
            {to_string(@status || "MODIFIED")}
          </span>
        </div>

        <div class="flex items-center gap-2 shrink-0">
          <%!-- File Actions: Revert File & Accept All OR Rollback to Checkpoint --%>
          <%= if @is_checkpoint and @rollback_tx_id do %>
            <button
              type="button"
              phx-click="rollback_to_checkpoint"
              phx-value-tx_id={@rollback_tx_id}
              class="px-2.5 py-1 bg-danger/20 hover:bg-danger/30 text-danger border border-danger/30 rounded-lg text-xs font-mono transition-smooth flex items-center gap-1 font-semibold"
              title="Rollback workspace to this checkpoint"
            >
              <.icon name="hero-arrow-uturn-left" class="w-3.5 h-3.5" />
              <span class="hidden sm:inline">1-Click Rollback</span>
            </button>
          <% end %>

          <%= if not @is_checkpoint and @file_path do %>
            <button
              type="button"
              phx-click="revert_file"
              phx-value-file={@file_path}
              data-confirm="Revert every uncommitted change in this file?"
              class="px-2.5 py-1 bg-danger/10 hover:bg-danger/20 text-danger border border-danger/30 rounded-lg text-xs font-mono transition-smooth flex items-center gap-1"
              title="Revert entire file to clean git state"
            >
              <.icon name="hero-arrow-uturn-left" class="w-3.5 h-3.5" />
              <span class="hidden sm:inline">Revert File</span>
            </button>
            <button
              type="button"
              phx-click="accept_all_hunks"
              phx-value-file={@file_path}
              class="px-2.5 py-1 bg-success/20 hover:bg-success/30 text-success border border-success/30 rounded-lg text-xs font-mono transition-smooth flex items-center gap-1"
              title="Stage all changes for this file"
            >
              <.icon name="hero-check" class="w-3.5 h-3.5" />
              <span class="hidden sm:inline">Accept All</span>
            </button>
          <% end %>

          <%!-- View Mode Toggle --%>
          <div class="flex items-center bg-inset p-1 rounded-lg border border-line">
            <button
              type="button"
              phx-click="set_diff_mode"
              phx-value-mode="inline"
              class={[
                "px-2.5 py-1 rounded text-xs transition-smooth",
                @diff_mode == "inline" && "bg-raised text-content font-semibold",
                @diff_mode != "inline" && "text-muted hover:text-content"
              ]}
            >
              Inline
            </button>
            <button
              type="button"
              phx-click="set_diff_mode"
              phx-value-mode="split"
              class={[
                "px-2.5 py-1 rounded text-xs transition-smooth",
                @diff_mode == "split" && "bg-raised text-content font-semibold",
                @diff_mode != "split" && "text-muted hover:text-content"
              ]}
            >
              Side-by-Side
            </button>
          </div>

          <%!-- Copy Diff Button --%>
          <button
            type="button"
            id={"#{@id}-copy-btn"}
            phx-hook="CodeCopy"
            data-code={@diff_text}
            class="px-2.5 py-1 bg-raised hover:bg-raised text-muted rounded-lg text-xs font-mono transition-smooth flex items-center gap-1.5"
          >
            <.icon name="hero-clipboard-document" class="w-3.5 h-3.5" />
            <span class="hidden md:inline">Copy Diff</span>
          </button>
        </div>
      </div>

      <%!-- Diff Body with Granular Hunks --%>
      <div class="flex-1 min-h-0 min-w-0 overflow-auto font-mono text-xs leading-relaxed p-2 sm:p-3 bg-inset space-y-4">
        <%= if is_nil(@diff_text) or String.trim(@diff_text) == "" do %>
          <.orbital_empty
            id={"#{@id}-empty"}
            title="No patch or diff selected."
            description="Choose a changed file to review its patch and manage individual hunks."
            icon="hero-code-bracket-square"
          />
        <% else %>
          <%= if @resolved_hunks != [] do %>
            <%= for hunk <- @resolved_hunks do %>
              <.hunk_card
                parent_id={@id}
                hunk={hunk}
                file_path={@file_path}
                diff_mode={@diff_mode}
                staged={@staged}
                is_checkpoint={@is_checkpoint}
                rollback_tx_id={@rollback_tx_id}
              />
            <% end %>
          <% else %>
            <%!-- Fallback to plain line renderer if no hunks parsed --%>
            <%= if @diff_mode == "inline" do %>
              <.inline_diff diff={@diff_text} />
            <% else %>
              <.split_diff diff={@diff_text} />
            <% end %>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders an individual hunk card with hunk header and Accept / Reject / Revert action buttons.
  """
  attr :parent_id, :string, default: "diff-viewer-container"
  attr :hunk, :any, required: true
  attr :file_path, :string, default: nil
  attr :diff_mode, :string, default: "inline"
  attr :staged, :boolean, default: false
  attr :is_checkpoint, :boolean, default: false
  attr :rollback_tx_id, :string, default: nil

  def hunk_card(assigns) do
    ~H"""
    <div
      id={"#{@parent_id}-hunk-card-#{@hunk.id}"}
      class="orbital-diff-hunk border border-line rounded-xl overflow-hidden bg-surface"
    >
      <%!-- Hunk Control Header --%>
      <div class="bg-raised px-3 py-2 border-b border-line flex items-center justify-between font-mono text-xs">
        <div class="flex items-center gap-2 truncate">
          <span class="px-2 py-0.5 rounded bg-accent/10 text-accent font-semibold text-[11px] border border-accent/30">
            {@hunk.header ||
              "@@ -#{@hunk.old_start},#{@hunk.old_count || @hunk.old_lines} +#{@hunk.new_start},#{@hunk.new_count || @hunk.new_lines} @@"}
          </span>
          <span class="text-[10px] text-muted">
            Hunk {@hunk.id}
          </span>
        </div>

        <div class="flex items-center gap-1.5">
          <%= if @is_checkpoint do %>
            <%= if @rollback_tx_id do %>
              <button
                type="button"
                phx-click="rollback_to_checkpoint"
                phx-value-tx_id={@rollback_tx_id}
                class="px-2 py-1 bg-danger/20 hover:bg-danger/30 text-danger border border-danger/30 rounded text-[11px] font-semibold transition-smooth flex items-center gap-1"
                title="Rollback to this checkpoint"
              >
                <.icon name="hero-arrow-uturn-left" class="w-3 h-3" />
                <span>Revert Hunk</span>
              </button>
            <% end %>
          <% else %>
            <%= if @staged do %>
              <button
                type="button"
                phx-click="unstage_hunk"
                phx-value-file={@file_path}
                phx-value-hunk_id={@hunk.id}
                class="px-2 py-1 bg-warning/20 hover:bg-warning/30 text-warning border border-warning/30 rounded text-[11px] font-semibold transition-smooth flex items-center gap-1"
                title="Unstage this hunk from the index"
              >
                <.icon name="hero-minus-circle" class="w-3 h-3" />
                <span>Unstage Hunk</span>
              </button>
            <% else %>
              <button
                type="button"
                phx-click="accept_hunk"
                phx-value-file={@file_path}
                phx-value-hunk_id={@hunk.id}
                class="px-2 py-1 bg-success/20 hover:bg-success/30 text-success border border-success/30 rounded text-[11px] font-semibold transition-smooth flex items-center gap-1"
                title="Stage this hunk"
              >
                <.icon name="hero-check" class="w-3 h-3" />
                <span>Accept Hunk</span>
              </button>
              <button
                type="button"
                phx-click="reject_hunk"
                phx-value-file={@file_path}
                phx-value-hunk_id={@hunk.id}
                data-confirm="Discard this hunk?"
                class="px-2 py-1 bg-danger/20 hover:bg-danger/30 text-danger border border-danger/30 rounded text-[11px] font-semibold transition-smooth flex items-center gap-1"
                title="Reject / Discard this hunk"
              >
                <.icon name="hero-x-mark" class="w-3 h-3" />
                <span>Reject Hunk</span>
              </button>
              <button
                type="button"
                phx-click="revert_hunk"
                phx-value-file={@file_path}
                phx-value-hunk_id={@hunk.id}
                data-confirm="Revert this hunk?"
                class="px-2 py-1 bg-raised/40 hover:bg-raised/60 text-muted border border-subtle/30 rounded text-[11px] transition-smooth flex items-center gap-1"
                title="Revert this hunk"
              >
                <.icon name="hero-arrow-uturn-left" class="w-3 h-3" />
                <span>Revert</span>
              </button>
            <% end %>
          <% end %>
        </div>
      </div>

      <%!-- Hunk Body Lines --%>
      <div class="p-2 bg-inset overflow-x-auto">
        <%= if @diff_mode == "inline" do %>
          <.hunk_inline_lines lines={@hunk.lines} />
        <% else %>
          <.hunk_split_lines lines={@hunk.lines} />
        <% end %>
      </div>
    </div>
    """
  end

  def hunk_inline_lines(assigns) do
    prepared_lines = IexCodeWeb.DiffHighlighter.prepare_inline_lines(assigns.lines)
    assigns = assign(assigns, :prepared_lines, prepared_lines)

    ~H"""
    <div class="space-y-0.5 font-mono text-xs">
      <%= for %{line: line, segments: segments} <- @prepared_lines do %>
        <% {bg, text_color, sign} =
          case line.type do
            :addition ->
              {"bg-success/10 border-l-2 border-success", "text-success", "+"}

            :deletion ->
              {"bg-danger/10 border-l-2 border-danger", "text-danger", "-"}

            :header ->
              {"bg-accent/10 text-accent font-semibold py-0.5 px-2 rounded", "text-accent", "@"}

            _ ->
              {"hover:bg-raised", "text-muted", " "}
          end %>
        <div class={["flex items-center px-2 py-0.5 rounded", bg]}>
          <span class="w-8 text-right text-subtle select-none pr-2 text-[10px]">{line.old_num || " "}</span>
          <span class="w-8 text-right text-subtle select-none pr-3 text-[10px]">{line.new_num || " "}</span>
          <span class="w-4 text-center select-none font-bold text-[11px] text-subtle">{sign}</span>
          <div class={["flex-1 overflow-x-auto", text_color]}>
            <IexCodeWeb.DiffHighlighter.diff_line_content
              segments={segments}
              type={line.type}
            />
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  def hunk_split_lines(assigns) do
    pairs = IexCodeWeb.DiffHighlighter.pair_split_lines(assigns.lines)
    assigns = assign(assigns, :pairs, pairs)

    ~H"""
    <div class="space-y-0.5 font-mono text-xs">
      <%!-- Header --%>
      <div class="grid grid-cols-2 gap-2 text-subtle text-[10px] uppercase font-bold px-2 py-1 bg-surface rounded mb-1">
        <div class="pr-2 border-r border-line">Original</div>
        <div class="pl-2">Modified</div>
      </div>

      <%!-- Aligned Rows --%>
      <%= for {left, right} <- @pairs do %>
        <% {left_segments, right_segments} =
          case {left, right} do
            {%{type: :deletion, content: c1}, %{type: :addition, content: c2}} ->
              diff = IexCodeWeb.DiffHighlighter.word_diff(c1, c2)

              {IexCodeWeb.DiffHighlighter.line_segments(diff, :deletion),
               IexCodeWeb.DiffHighlighter.line_segments(diff, :addition)}

            {%{type: :deletion, content: c1}, _} ->
              {[{:highlight, c1}], []}

            {_, %{type: :addition, content: c2}} ->
              {[], [{:highlight, c2}]}

            {%{type: :context, content: c}, %{type: :context}} ->
              {[{:normal, c}], [{:normal, c}]}

            _ ->
              {[], []}
          end %>
        <div class="grid grid-cols-2 gap-2 group hover:bg-raised/30">
          <%!-- Left (Original / Deletion) Column --%>
          <div class="border-r border-line pr-2">
            <%= if is_nil(left) or left == :empty do %>
              <div class="px-2 py-0.5 rounded flex items-center min-h-[1.5rem] bg-inset/40 select-none text-transparent border-l-2 border-transparent">
                <span class="w-8 text-right pr-2 text-[10px] select-none text-transparent">·</span>
                <span class="flex-1 select-none text-transparent">&nbsp;</span>
              </div>
            <% else %>
              <div class={[
                "px-2 py-0.5 rounded flex items-center min-h-[1.5rem]",
                left.type == :deletion && "bg-danger/10 text-danger border-l-2 border-danger",
                left.type == :context && "text-muted hover:bg-raised",
                left.type == :eof_newline && "text-subtle italic text-[10px]"
              ]}>
                <span class="w-8 text-right text-subtle select-none pr-2 text-[10px]">
                  {left.old_num || " "}
                </span>
                <div class="flex-1 overflow-x-auto">
                  <IexCodeWeb.DiffHighlighter.diff_line_content
                    segments={left_segments}
                    type={left.type}
                  />
                </div>
              </div>
            <% end %>
          </div>

          <%!-- Right (Modified / Addition) Column --%>
          <div class="pl-2">
            <%= if is_nil(right) or right == :empty do %>
              <div class="px-2 py-0.5 rounded flex items-center min-h-[1.5rem] bg-inset/40 select-none text-transparent border-l-2 border-transparent">
                <span class="w-8 text-right pr-2 text-[10px] select-none text-transparent">·</span>
                <span class="flex-1 select-none text-transparent">&nbsp;</span>
              </div>
            <% else %>
              <div class={[
                "px-2 py-0.5 rounded flex items-center min-h-[1.5rem]",
                right.type == :addition &&
                  "bg-success/10 text-success border-l-2 border-success",
                right.type == :context && "text-muted hover:bg-raised",
                right.type == :eof_newline && "text-subtle italic text-[10px]"
              ]}>
                <span class="w-8 text-right text-subtle select-none pr-2 text-[10px]">
                  {right.new_num || " "}
                </span>
                <div class="flex-1 overflow-x-auto">
                  <IexCodeWeb.DiffHighlighter.diff_line_content
                    segments={right_segments}
                    type={right.type}
                  />
                </div>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  def inline_diff(assigns) do
    lines = String.split(assigns.diff, ~r/\r?\n/)
    assigns = assign(assigns, lines: lines)

    ~H"""
    <div class="space-y-0.5">
      <%= for {line, idx} <- Enum.with_index(@lines, 1) do %>
        <% {bg, text_color, sign} =
          cond do
            String.starts_with?(line, "+") && !String.starts_with?(line, "+++") ->
              {"bg-success/10 border-l-2 border-success", "text-success", "+"}

            String.starts_with?(line, "-") && !String.starts_with?(line, "---") ->
              {"bg-danger/10 border-l-2 border-danger", "text-danger", "-"}

            String.starts_with?(line, "@@") ->
              {"bg-accent/10 text-accent font-semibold my-1 py-0.5 px-2 rounded", "text-accent", "@"}

            String.starts_with?(line, "---") || String.starts_with?(line, "+++") ->
              {"bg-raised text-muted font-semibold py-1 px-2", "text-muted", "#"}

            true ->
              {"hover:bg-surface", "text-muted", " "}
          end %>
        <div class={["flex items-center px-2 py-0.5 rounded font-mono", bg]}>
          <span class="w-10 text-right text-subtle select-none pr-3 text-[10px]">{idx}</span>
          <span class="w-4 text-center select-none font-bold text-[11px] text-subtle">{sign}</span>
          <span class={["flex-1 whitespace-pre-wrap", text_color]}>{line}</span>
        </div>
      <% end %>
    </div>
    """
  end

  def split_diff(assigns) do
    lines = String.split(assigns.diff, ~r/\r?\n/)
    assigns = assign(assigns, lines: lines)

    ~H"""
    <div class="grid min-w-[42rem] grid-cols-2 gap-2">
      <div class="space-y-0.5 border-r border-line pr-2">
        <div class="text-subtle text-[10px] uppercase font-bold px-2 py-1 bg-surface rounded mb-1">
          Original
        </div>
        <%= for {line, idx} <- Enum.with_index(@lines, 1) do %>
          <%= if !String.starts_with?(line, "+") || String.starts_with?(line, "+++") do %>
            <div class={[
              "px-2 py-0.5 rounded flex items-center",
              String.starts_with?(line, "-") &&
                "bg-danger/10 text-danger border-l-2 border-danger"
            ]}>
              <span class="w-8 text-right text-subtle select-none pr-2 text-[10px]">{idx}</span>
              <span class="flex-1 whitespace-pre-wrap">{line}</span>
            </div>
          <% end %>
        <% end %>
      </div>
      <div class="space-y-0.5 pl-2">
        <div class="text-subtle text-[10px] uppercase font-bold px-2 py-1 bg-surface rounded mb-1">
          Modified
        </div>
        <%= for {line, idx} <- Enum.with_index(@lines, 1) do %>
          <%= if !String.starts_with?(line, "-") || String.starts_with?(line, "---") do %>
            <div class={[
              "px-2 py-0.5 rounded flex items-center",
              String.starts_with?(line, "+") &&
                "bg-success/10 text-success border-l-2 border-success"
            ]}>
              <span class="w-8 text-right text-subtle select-none pr-2 text-[10px]">{idx}</span>
              <span class="flex-1 whitespace-pre-wrap">{line}</span>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # ============================================================================
  # F8: Interactive Inline Code Editor & File Explorer (<.file_explorer>)
  # ============================================================================

  @doc """
  Renders an interactive inline code editor and file directory tree with:
  - Open buffer tabs (`@open_buffers`)
  - Dirty state tracking and visual indicator (`●`)
  - Gutter line numbers and Tab key indentation (via `.CodeEditor` hook)
  - `Cmd+S` save hotkey and explicit Save / Revert buttons
  """
  attr :files, :list, default: []
  attr :filter, :string, default: ""
  attr :filter_form, :any, default: nil
  attr :expanded_folders, :any, default: MapSet.new()
  attr :selected_file, :string, default: nil
  attr :file_content, :string, default: nil
  attr :dirty_content, :string, default: nil
  attr :is_dirty, :boolean, default: false
  attr :open_buffers, :list, default: []
  attr :editor_lock, :map, default: nil
  attr :auto_save, :boolean, default: false

  def file_explorer(assigns) do
    has_filter = assigns.filter != "" and not is_nil(assigns.filter)
    expanded = assigns.expanded_folders || MapSet.new()

    tree_items =
      if has_filter do
        query = String.downcase(assigns.filter)

        assigns.files
        |> Enum.filter(&String.contains?(String.downcase(&1), query))
        |> Enum.map(fn file ->
          %{type: :file, name: file, path: file, depth: 0}
        end)
      else
        assigns.files
        |> build_file_tree()
        |> flatten_file_tree(expanded, 0)
      end

    current_text = assigns.dirty_content || assigns.file_content || ""
    editor_locked? = not is_nil(assigns.editor_lock)

    assigns =
      assigns
      |> assign(:tree_items, tree_items)
      |> assign(:has_filter, has_filter)
      |> assign(:current_text, current_text)
      |> assign(:editor_locked?, editor_locked?)
      |> assign(:filter_form, assigns.filter_form || to_form(%{"filter" => assigns.filter}))

    ~H"""
    <div
      id="file-explorer-container"
      class="orbital-panel orbital-file-explorer flex-1 flex min-h-0 min-w-0 flex-col overflow-hidden bg-inset md:flex-row"
    >
      <%!-- Left Tree / List Navigation --%>
      <aside
        id="file-tree-panel"
        aria-label="Project files"
        class="flex h-[min(38%,20rem)] w-full shrink-0 flex-col overflow-hidden border-b border-line bg-surface md:h-full md:w-64 md:border-r md:border-b-0 xl:w-72"
      >
        <%!-- Search Header --%>
        <div class="p-3 border-b border-line">
          <.form
            for={@filter_form}
            id="file-filter-form"
            phx-change="filter_files"
            class="relative [&>div]:mb-0"
          >
            <.input
              id="file-filter-input"
              type="text"
              field={@filter_form[:filter]}
              aria-label="Search project files"
              placeholder="Search files…"
              class="w-full bg-inset border border-line rounded-xl px-3 py-1.5 pl-8 text-xs text-content placeholder:text-subtle font-mono focus:border-accent focus:outline-none"
            />
            <.icon name="hero-magnifying-glass" class="w-4 h-4 text-muted absolute left-2.5 top-2" />
          </.form>
          <div class="flex items-center justify-between mt-2 px-1 text-[11px] font-mono text-muted">
            <span>{if @has_filter, do: length(@tree_items), else: length(@files)} files</span>
            <button
              phx-click="refresh_files"
              class="hover:text-content transition-smooth flex items-center gap-1"
            >
              <.icon name="hero-arrow-path" class="w-3 h-3" /> Refresh
            </button>
          </div>
        </div>

        <%!-- Files List & Hierarchical Tree --%>
        <div class="flex-1 overflow-y-auto p-2 space-y-0.5 font-mono text-xs">
          <div
            :if={@tree_items == []}
            id="file-tree-empty"
            class="px-3 py-5 text-xs leading-5 text-subtle"
          >
            {if @has_filter, do: "No files match your search.", else: "No files in this workspace."}
          </div>
          <%= for item <- @tree_items do %>
            <%= if item.type == :dir do %>
              <button
                type="button"
                phx-click="toggle_folder"
                phx-value-path={item.path}
                style={"padding-left: #{item.depth * 12 + 6}px"}
                class="w-full text-left py-1 pr-2 rounded-lg truncate transition-smooth flex items-center gap-1.5 text-muted hover:text-content hover:bg-raised group"
              >
                <.icon
                  name={if item.expanded, do: "hero-chevron-down", else: "hero-chevron-right"}
                  class="w-3 h-3 text-subtle group-hover:text-content shrink-0"
                />
                <.icon
                  name={if item.expanded, do: "hero-folder-open", else: "hero-folder"}
                  class="w-3.5 h-3.5 text-warning shrink-0"
                />
                <span class="truncate font-medium text-muted group-hover:text-content">{item.name}</span>
              </button>
            <% else %>
              <% is_open = Enum.any?(@open_buffers, &(&1.path == item.path))
              buffer = Enum.find(@open_buffers, &(&1.path == item.path))
              is_buffer_dirty = buffer && buffer.dirty? %>
              <button
                type="button"
                phx-click="select_file"
                phx-value-path={item.path}
                style={"padding-left: #{if @has_filter, do: 8, else: item.depth * 12 + 16}px"}
                class={[
                  "w-full text-left py-1.5 pr-2.5 rounded-lg truncate transition-smooth flex items-center justify-between gap-2 group",
                  @selected_file == item.path &&
                    "bg-raised text-accent font-medium shadow-sm border border-line",
                  @selected_file != item.path &&
                    "text-muted hover:text-content hover:bg-raised"
                ]}
              >
                <div class="flex items-center gap-2 truncate">
                  <.icon
                    name={file_icon(item.name)}
                    class={["w-3.5 h-3.5 shrink-0", @selected_file == item.path && "text-accent"]}
                  />
                  <span class="truncate">{item.name}</span>
                </div>
                <div class="flex items-center gap-1 shrink-0">
                  <%= if is_buffer_dirty do %>
                    <span
                      class="w-2 h-2 rounded-full bg-warning"
                      title="Unsaved changes"
                    ></span>
                  <% else %>
                    <%= if is_open do %>
                      <span class="w-1.5 h-1.5 rounded-full bg-accent/60" title="Open tab"></span>
                    <% end %>
                  <% end %>
                </div>
              </button>
            <% end %>
          <% end %>
        </div>
      </aside>

      <%!-- Right Interactive Code Editor Viewport --%>
      <div
        id="file-editor-panel"
        class="flex min-h-0 min-w-0 flex-1 flex-col bg-inset overflow-hidden"
      >
        <%= if @selected_file do %>
          <%!-- Open Buffer Tabs Bar --%>
          <div class="flex items-center bg-surface border-b border-line overflow-x-auto px-2 pt-1.5 gap-1 shrink-0">
            <%= for tab <- @open_buffers do %>
              <% is_active = tab.path == @selected_file %>
              <div class={[
                "flex items-center gap-2 px-3 py-1.5 rounded-t-xl text-xs font-mono transition-smooth border-t border-x border-line group shrink-0",
                is_active && "bg-inset text-accent font-medium border-b-0",
                !is_active && "bg-raised text-muted hover:text-content hover:bg-raised"
              ]}>
                <button
                  type="button"
                  phx-click="select_file"
                  phx-value-path={tab.path}
                  class="flex items-center gap-1.5 truncate max-w-[160px]"
                >
                  <.icon name={file_icon(tab.path)} class="w-3.5 h-3.5 shrink-0" />
                  <span class="truncate">{Path.basename(tab.path)}</span>
                </button>

                <%= if tab.dirty? do %>
                  <span class="w-2 h-2 rounded-full bg-warning shrink-0" title="Unsaved changes">●</span>
                <% end %>

                <button
                  type="button"
                  phx-click="close_file_buffer"
                  phx-value-path={tab.path}
                  aria-label={"Close #{Path.basename(tab.path)} buffer"}
                  class="text-subtle hover:text-danger p-0.5 rounded transition-smooth ml-1 shrink-0"
                  title="Close buffer"
                >
                  <.icon name="hero-x-mark" class="w-3 h-3" />
                </button>
              </div>
            <% end %>
          </div>

          <%!-- Active File Toolbar --%>
          <div class="file-editor-toolbar p-2.5 border-b border-line bg-raised flex flex-wrap items-center justify-between gap-2 shrink-0 font-mono text-xs">
            <div class="flex items-center gap-2 min-w-0">
              <.icon name={file_icon(@selected_file)} class="w-4 h-4 text-accent shrink-0" />
              <span class="text-content font-semibold truncate">{@selected_file}</span>
              <%= if @is_dirty do %>
                <span class="text-[10px] font-mono text-warning bg-warning/10 border border-warning/30 px-2 py-0.5 rounded font-semibold shrink-0">
                  ● Unsaved Changes
                </span>
              <% end %>
            </div>

            <%!-- Editor Action Buttons: Revert, Save, Copy --%>
            <div class="flex max-w-full items-center gap-1.5 sm:gap-2 shrink-0 overflow-x-auto">
              <%= if @is_dirty do %>
                <button
                  phx-click="revert_file_buffer"
                  class="px-2.5 py-1 bg-raised/40 hover:bg-raised/60 text-muted border border-subtle/30 rounded-lg text-xs font-mono transition-smooth flex items-center gap-1"
                  title="Discard unsaved buffer edits"
                >
                  <.icon name="hero-arrow-uturn-left" class="w-3.5 h-3.5" />
                  <span class="hidden sm:inline">Revert</span>
                </button>
              <% end %>

              <button
                id="save-file-btn"
                phx-click="save_file"
                disabled={@editor_locked?}
                class={[
                  "px-3 py-1 rounded-lg text-xs font-mono font-semibold transition-smooth flex items-center gap-1.5",
                  @editor_locked? &&
                    "cursor-not-allowed bg-danger/10 text-danger/60 border border-danger/20",
                  @is_dirty &&
                    !@editor_locked? &&
                    "bg-accent hover:bg-accent-strong text-accent-ink",
                  !@is_dirty && !@editor_locked? &&
                    "bg-raised text-muted hover:text-content"
                ]}
                title={
                  if(@editor_locked?,
                    do: "Save unavailable while another session owns this workspace resource",
                    else: "Save file to disk (Cmd+S)"
                  )
                }
              >
                <.icon name="hero-document-check" class="w-3.5 h-3.5" />
                <span>Save</span>
                <span class="text-[10px] opacity-70 hidden sm:inline">⌘S</span>
              </button>

              <button
                id="copy-file-btn"
                phx-hook="CodeCopy"
                data-code={@current_text}
                class="px-2.5 py-1 bg-raised hover:bg-raised text-muted rounded-lg text-xs font-mono transition-smooth flex items-center gap-1.5"
              >
                <.icon name="hero-clipboard-document" class="w-3.5 h-3.5" />
                <span class="hidden sm:inline">Copy</span>
              </button>
            </div>
          </div>

          <%= if @editor_locked? do %>
            <div
              id="editor-lock-ribbon"
              role="status"
              data-lock-state="foreign"
              data-lock-resource={@editor_lock.resource_type}
              class="flex items-center justify-between gap-4 border-b border-danger/30 bg-danger/10 px-3 py-2 font-mono text-xs text-danger"
            >
              <div class="flex min-w-0 items-center gap-2">
                <.icon name="hero-lock-closed" class="h-4 w-4 shrink-0 text-danger" />
                <span class="truncate">
                  Read-only while
                  <strong class="text-danger">{workspace_lock_label(@editor_lock)}</strong>
                  holds the {editor_lock_label(@editor_lock)} lock. Your unsaved buffer is safe.
                </span>
              </div>
              <button
                id="retry-file-lock-btn"
                type="button"
                phx-click="retry_file_lock"
                class="shrink-0 rounded-lg border border-danger/30 bg-danger/10 px-2.5 py-1 font-semibold text-danger transition hover:border-danger/60 hover:bg-danger/20"
              >
                Retry access
              </button>
            </div>
          <% end %>

          <%!-- Code Editor Body with Line Numbers & Colocated JS Hook --%>
          <div
            id="code-editor-viewport"
            phx-hook=".CodeEditor"
            data-auto-save={to_string(@auto_save)}
            class="flex-1 flex overflow-hidden bg-inset relative font-mono text-xs"
          >
            <%!-- Line Numbers Gutter --%>
            <div class="editor-gutter w-12 bg-inset border-r border-line py-3 pr-2 text-right text-subtle select-none overflow-hidden shrink-0 font-mono text-[11px] leading-relaxed">
            </div>

            <%!-- Code Input Textarea --%>
            <textarea
              id="code-editor-textarea"
              name="file_content"
              spellcheck="false"
              autocomplete="off"
              autocorrect="off"
              autocapitalize="off"
              readonly={@editor_locked?}
              aria-readonly={to_string(@editor_locked?)}
              class={[
                "flex-1 bg-transparent border-0 p-3 text-muted font-mono text-xs leading-relaxed focus:outline-none focus:ring-0 resize-none overflow-auto whitespace-pre tab-2",
                @editor_locked? && "cursor-not-allowed bg-danger/10 text-muted"
              ]}
            ><%= @current_text %></textarea>
          </div>

          <script :type={Phoenix.LiveView.ColocatedHook} name=".CodeEditor">
            export default {
              mounted() {
                this.textarea = this.el.querySelector('textarea');
                this.gutter = this.el.querySelector('.editor-gutter');
                this.autoSaveTimer = null;
                this.updateGutter();

                this.textarea.addEventListener('input', () => {
                  this.updateGutter();
                  this.pushEvent('file_content_changed', { content: this.textarea.value });

                  clearTimeout(this.autoSaveTimer);
                  if (this.el.dataset.autoSave === 'true' && !this.textarea.readOnly) {
                    this.autoSaveTimer = setTimeout(() => {
                      this.pushEvent('save_file', {
                        content: this.textarea.value,
                        autosave: true
                      });
                    }, 900);
                  }
                });

                this.textarea.addEventListener('keydown', (e) => {
                  if ((e.metaKey || e.ctrlKey) && e.key === 's') {
                    e.preventDefault();
                    if (this.textarea.readOnly) return;
                    clearTimeout(this.autoSaveTimer);
                    this.pushEvent('save_file', { content: this.textarea.value });
                  }
                  if (e.key === 'Tab') {
                    if (this.textarea.readOnly) return;
                    e.preventDefault();
                    const start = this.textarea.selectionStart;
                    const end = this.textarea.selectionEnd;
                    this.textarea.value = this.textarea.value.substring(0, start) + '  ' + this.textarea.value.substring(end);
                    this.textarea.selectionStart = this.textarea.selectionEnd = start + 2;
                    this.updateGutter();
                    this.pushEvent('file_content_changed', { content: this.textarea.value });
                  }
                });

                this.textarea.addEventListener('scroll', () => {
                  if (this.gutter) {
                    this.gutter.scrollTop = this.textarea.scrollTop;
                  }
                });

                this.handleEvent('jump_to_editor_line', ({line, file}) => {
                  setTimeout(() => {
                    if (!this.textarea) return;
                    const lines = this.textarea.value.split('\n');
                    const targetLine = parseInt(line, 10) || 1;
                    let charPos = 0;
                    for (let i = 0; i < Math.min(targetLine - 1, lines.length); i++) {
                      charPos += lines[i].length + 1;
                    }
                    this.textarea.focus();
                    const lineLen = lines[targetLine - 1] ? lines[targetLine - 1].length : 0;
                    this.textarea.setSelectionRange(charPos, charPos + lineLen);
                    const lineHeight = 18;
                    this.textarea.scrollTop = Math.max(0, (targetLine - 5) * lineHeight);
                    if (this.gutter) {
                      this.gutter.scrollTop = this.textarea.scrollTop;
                    }
                  }, 50);
                });
              },
              updated() {
                this.updateGutter();
              },
              destroyed() {
                clearTimeout(this.autoSaveTimer);
              },
              updateGutter() {
                if (!this.gutter || !this.textarea) return;
                const lineCount = (this.textarea.value.match(/\n/g) || []).length + 1;
                let numbers = '';
                for (let i = 1; i <= lineCount; i++) {
                  numbers += `<div>${i}</div>`;
                }
                this.gutter.innerHTML = numbers;
              }
            }
          </script>
        <% else %>
          <.orbital_empty
            id="file-editor-empty"
            title="Your source, in focus"
            description="Choose a workspace file to inspect its contents and make changes."
            icon="hero-folder-open"
            class="flex-1"
          />
        <% end %>
      </div>
    </div>
    """
  end

  defp editor_lock_label(%{resource_type: "project"}), do: "project"
  defp editor_lock_label(%{resource_type: "file"}), do: "file"
  defp editor_lock_label(_lock), do: "workspace"

  defp file_icon(path) do
    path_str = to_string(path || "")

    cond do
      String.ends_with?(path_str, [".ex", ".exs"]) -> "hero-cube"
      String.ends_with?(path_str, [".heex", ".html"]) -> "hero-code-bracket"
      String.ends_with?(path_str, [".css", ".scss"]) -> "hero-paint-brush"
      String.ends_with?(path_str, [".js", ".ts"]) -> "hero-bolt"
      String.ends_with?(path_str, [".json", ".yaml", ".yml"]) -> "hero-document-text"
      String.ends_with?(path_str, [".md", ".markdown"]) -> "hero-document"
      true -> "hero-document"
    end
  end

  defp build_file_tree(files) do
    Enum.reduce(files, %{}, fn file, acc ->
      parts = Path.split(file)
      put_file_in_tree(acc, parts, file)
    end)
  end

  defp put_file_in_tree(acc, [filename], full_path) do
    Map.put(acc, filename, {:file, filename, full_path})
  end

  defp put_file_in_tree(acc, [dir | rest], full_path) do
    dir_entry =
      case Map.get(acc, dir) do
        {:dir, name, path, children} ->
          {:dir, name, path, children}

        _ ->
          full_parts = Path.split(full_path)
          dir_idx = Enum.find_index(full_parts, &(&1 == dir))

          dir_path =
            if dir_idx do
              full_parts |> Enum.take(dir_idx + 1) |> Path.join()
            else
              dir
            end

          {:dir, dir, dir_path, %{}}
      end

    {:dir, name, path, children} = dir_entry
    updated_children = put_file_in_tree(children, rest, full_path)
    Map.put(acc, dir, {:dir, name, path, updated_children})
  end

  defp flatten_file_tree(tree, expanded_folders, depth) do
    tree
    |> Enum.sort_by(fn
      {name, {:dir, _, _, _}} -> {0, String.downcase(name)}
      {name, {:file, _, _}} -> {1, String.downcase(name)}
    end)
    |> Enum.flat_map(fn
      {_name, {:dir, name, path, children}} ->
        is_expanded = MapSet.member?(expanded_folders, path)
        item = %{type: :dir, name: name, path: path, depth: depth, expanded: is_expanded}

        if is_expanded do
          [item | flatten_file_tree(children, expanded_folders, depth + 1)]
        else
          [item]
        end

      {_name, {:file, name, full_path}} ->
        [%{type: :file, name: name, path: full_path, depth: depth}]
    end)
  end

  # ============================================================================
  # F9: Interactive xterm.js Terminal Session (<.terminal_session>)
  # ============================================================================

  @doc """
  Renders an interactive PTY terminal session powered by xterm.js.
  Includes a top toolbar with shell badges, dimensions, quick actions,
  terminal lifecycle controls, visual active agent indicator, and xterm canvas viewport.
  """
  attr :session, :any, default: nil
  attr :running, :boolean, default: true
  attr :status, :atom, default: :running
  attr :shell, :string, default: "zsh"
  attr :cols, :integer, default: 80
  attr :rows, :integer, default: 24
  attr :occupant, :any, default: :user
  attr :active_cmd, :string, default: nil
  attr :output, :string, default: ""
  attr :form, :any, default: nil
  attr :workspace_locks, :list, default: []

  def terminal_session(assigns) do
    session_id =
      case assigns[:session] do
        %{id: id} -> id
        id when is_binary(id) and id != "" -> id
        _ -> "default"
      end

    owner_id = "terminal-session:#{session_id}"

    foreign_lock =
      Enum.find(assigns.workspace_locks, fn lock ->
        workspace_lock_value(lock, :status) == "held" and
          workspace_lock_value(lock, :owner_id) != owner_id
      end)

    assigns =
      assigns
      |> assign(:session_id, session_id)
      |> assign(:monitor_only, not is_nil(foreign_lock))
      |> assign(:foreign_lock, foreign_lock)

    ~H"""
    <div
      id="terminal-session-container"
      class="orbital-panel orbital-terminal flex-1 flex flex-col h-full bg-inset p-5 gap-3 select-none overflow-hidden"
    >
      <%!-- Top Toolbar: Badges, Quick Actions, Controls --%>
      <div class="flex items-center justify-between shrink-0 font-mono text-xs flex-wrap gap-2">
        <%!-- Left: Shell Info, Dimensions, Quick Action Launchers --%>
        <div class="flex items-center gap-2 flex-wrap">
          <%!-- Shell Info Badge --%>
          <div
            id="terminal-shell-badge"
            class="flex items-center gap-1.5 px-2.5 py-1 bg-raised border border-line rounded-lg text-muted font-mono text-xs shadow-sm"
          >
            <span class={[
              "w-2 h-2 rounded-full",
              @status in [:running, :ready] &&
                "bg-success animate-pulse",
              @status == :restarting &&
                "bg-warning animate-spin",
              @status in [:stopped, :idle] && "bg-subtle"
            ]}></span>
            <span class="font-semibold text-muted">{@shell || "zsh"}</span>
            <span class="text-subtle text-[10px]">PTY</span>
          </div>

          <%!-- Dimensions Badge --%>
          <div
            id="terminal-dimensions-badge"
            class="px-2 py-1 bg-raised/70 border border-line/70 rounded-lg text-muted font-mono text-[11px] shadow-sm"
          >
            {@cols}x{@rows}
          </div>

          <div class="h-4 w-px bg-raised mx-1"></div>

          <%!-- Quick Action Buttons --%>
          <button
            id="btn-quick-iex"
            phx-click="run_terminal_quick_action"
            phx-value-cmd="iex -S mix"
            disabled={!@running or @monitor_only}
            class="px-2.5 py-1 bg-raised hover:bg-raised active:bg-raised border border-line rounded-lg text-accent hover:text-accent transition-smooth font-mono text-xs flex items-center gap-1.5 disabled:opacity-50 disabled:pointer-events-none group shadow-sm"
            title="Start Interactive Elixir Shell"
          >
            <.icon
              name="hero-bolt"
              class="w-3.5 h-3.5 text-accent group-hover:scale-110 transition-transform"
            />
            <span>iex -S mix</span>
          </button>

          <button
            id="btn-quick-test"
            phx-click="run_terminal_quick_action"
            phx-value-cmd="mix test"
            disabled={!@running or @monitor_only}
            class="px-2.5 py-1 bg-raised hover:bg-raised active:bg-raised border border-line rounded-lg text-success hover:text-success transition-smooth font-mono text-xs flex items-center gap-1.5 disabled:opacity-50 disabled:pointer-events-none group shadow-sm"
            title="Run Mix Test Suite"
          >
            <.icon
              name="hero-play"
              class="w-3.5 h-3.5 text-success group-hover:scale-110 transition-transform"
            />
            <span>mix test</span>
          </button>

          <button
            id="btn-quick-precommit"
            phx-click="run_terminal_quick_action"
            phx-value-cmd="mix precommit"
            disabled={!@running or @monitor_only}
            class="px-2.5 py-1 bg-raised hover:bg-raised active:bg-raised border border-line rounded-lg text-accent hover:text-accent transition-smooth font-mono text-xs flex items-center gap-1.5 disabled:opacity-50 disabled:pointer-events-none group shadow-sm"
            title="Run Precommit Quality Checks"
          >
            <.icon
              name="hero-check-badge"
              class="w-3.5 h-3.5 text-accent group-hover:scale-110 transition-transform"
            />
            <span>mix precommit</span>
          </button>

          <button
            id="btn-quick-git-status"
            phx-click="run_terminal_quick_action"
            phx-value-cmd="git status"
            disabled={!@running or @monitor_only}
            class="px-2.5 py-1 bg-raised hover:bg-raised active:bg-raised border border-line rounded-lg text-warning hover:text-warning transition-smooth font-mono text-xs flex items-center gap-1.5 disabled:opacity-50 disabled:pointer-events-none group shadow-sm"
            title="Check Git Working Directory Status"
          >
            <.icon
              name="hero-document-text"
              class="w-3.5 h-3.5 text-warning group-hover:scale-110 transition-transform"
            />
            <span>git status</span>
          </button>

          <button
            id="btn-quick-git-diff"
            phx-click="run_terminal_quick_action"
            phx-value-cmd="git diff"
            disabled={!@running or @monitor_only}
            class="px-2.5 py-1 bg-raised hover:bg-raised active:bg-raised border border-line rounded-lg text-warning hover:text-warning transition-smooth font-mono text-xs flex items-center gap-1.5 disabled:opacity-50 disabled:pointer-events-none group shadow-sm"
            title="Show Git Diff of Unstaged Changes"
          >
            <.icon
              name="hero-code-bracket"
              class="w-3.5 h-3.5 text-warning group-hover:scale-110 transition-transform"
            />
            <span>git diff</span>
          </button>
        </div>

        <%!-- Right: Terminal Controls (Clear, Restart, Kill) --%>
        <div class="flex items-center gap-2">
          <button
            id="btn-terminal-clear"
            phx-click="clear_terminal"
            class="px-2.5 py-1 bg-raised hover:bg-raised active:bg-raised border border-line rounded-lg text-muted hover:text-content transition-smooth font-mono text-xs flex items-center gap-1.5 shadow-sm"
            title="Clear Terminal Screen & Buffer"
          >
            <.icon name="hero-trash" class="w-3.5 h-3.5" />
            <span>Clear</span>
          </button>

          <button
            id="btn-terminal-restart"
            phx-click="restart_terminal_session"
            disabled={@monitor_only}
            class="px-2.5 py-1 bg-raised hover:bg-raised active:bg-raised border border-line rounded-lg text-info hover:text-info transition-smooth font-mono text-xs flex items-center gap-1.5 shadow-sm"
            title="Restart PTY Shell Process"
          >
            <.icon name="hero-arrow-path" class="w-3.5 h-3.5" />
            <span>Restart</span>
          </button>

          <button
            id="btn-terminal-kill"
            phx-click="kill_terminal_session"
            disabled={@monitor_only}
            class="px-2.5 py-1 bg-danger/10 hover:bg-danger/10 active:bg-danger/10 border border-danger/60 rounded-lg text-danger hover:text-danger transition-smooth font-mono text-xs flex items-center gap-1.5 shadow-sm"
            title="Send SIGINT / Interrupt Shell"
          >
            <.icon name="hero-stop" class="w-3.5 h-3.5 text-danger" />
            <span>Kill</span>
          </button>
        </div>
      </div>

      <%= if @monitor_only do %>
        <div
          id="terminal-workspace-lock-banner"
          role="status"
          data-lock-state="foreign"
          class="flex shrink-0 items-center justify-between gap-3 rounded-xl border border-info/25 bg-info/10 px-3.5 py-2 font-mono text-xs text-info"
        >
          <div class="flex items-center gap-2.5">
            <.icon name="hero-eye" class="size-4 text-info" />
            <span class="font-semibold">Monitor-only terminal</span>
            <span class="text-info/70">
              Workspace changes are locked by {workspace_lock_label(@foreign_lock)}.
            </span>
          </div>
          <span class="rounded-md border border-info/20 bg-inset px-2 py-0.5 text-[10px] uppercase tracking-wider text-info/70">
            Input disabled
          </span>
        </div>
      <% end %>

      <%!-- Visual Active Agent Banner --%>
      <%= if match?({:agent, _, _}, @occupant) or match?({:agent, _}, @occupant) do %>
        <% {agent_name, op_id} =
          case @occupant do
            {:agent, name, id} -> {name, id}
            {:agent, name} -> {name, nil}
            _ -> {"Agent", nil}
          end %>
        <div
          id="terminal-agent-banner"
          class="flex items-center justify-between px-3.5 py-2 bg-accent/10 border border-warning/30 rounded-xl text-xs font-mono text-warning shadow-lg animate-in fade-in slide-in-from-top-1 shrink-0"
        >
          <div class="flex items-center gap-2.5 flex-wrap">
            <span class="flex h-2.5 w-2.5 relative">
              <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-warning opacity-75"></span>
              <span class="relative inline-flex rounded-full h-2.5 w-2.5 bg-warning"></span>
            </span>
            <span class="font-bold text-warning">Agent active:</span>
            <span class="px-2 py-0.5 bg-warning/20 text-warning rounded font-semibold text-[11px] border border-warning/30">
              {agent_name}
            </span>
            <%= if @active_cmd do %>
              <span class="text-muted text-[11px]">Executing:</span>
              <code class="px-2 py-0.5 bg-inset text-content rounded font-mono text-[11px] border border-line">
                {@active_cmd}
              </code>
            <% end %>
            <%= if op_id do %>
              <span class="text-subtle text-[10px]">({op_id})</span>
            <% end %>
          </div>

          <div class="flex items-center gap-2 text-[11px] text-warning/80">
            <svg
              class="animate-spin h-3.5 w-3.5 text-warning"
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
            >
              <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
              </circle>
              <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8H4z"></path>
            </svg>
            <span class="italic text-[10px]">User input locked during autonomous execution</span>
          </div>
        </div>
      <% end %>

      <%!-- xterm Container Viewport --%>
      <div
        id="terminal-xterm-wrapper"
        class="flex-1 min-h-0 bg-inset border border-line rounded-2xl overflow-hidden shadow-2xl relative flex flex-col"
      >
        <div
          id="terminal-xterm-container"
          phx-hook="TerminalHook"
          phx-update="ignore"
          data-session-id={@session_id}
          data-monitor-only={to_string(@monitor_only)}
          aria-disabled={to_string(@monitor_only)}
          class="flex-1 w-full h-full p-2 bg-inset"
        >
        </div>
        <div id="terminal-rendered-output" class="hidden">
          {@output}
        </div>
      </div>

      <%!-- Quick Command Input Form --%>
      <%= if @form do %>
        <.form
          for={@form}
          id="terminal-form"
          phx-submit="run_terminal_command"
          class="flex gap-2 shrink-0"
        >
          <div class="relative flex-1 [&>div]:mb-0">
            <span class="absolute left-3 top-2.5 text-success font-mono text-xs font-bold">$</span>
            <.input
              id="terminal-command-input"
              type="text"
              field={@form[:command]}
              aria-label="Shell command"
              placeholder="Enter shell command..."
              disabled={!@running or @monitor_only}
              class="w-full bg-surface border border-line rounded-xl pl-7 pr-4 py-2 text-xs font-mono text-content focus:outline-none focus:border-success disabled:opacity-50"
            />
            <%= if @active_cmd do %>
              <span id="terminal-active-cmd" class="hidden">{@active_cmd}</span>
            <% end %>
          </div>
          <button
            type="submit"
            disabled={!@running or @monitor_only}
            class="px-4 py-2 bg-accent hover:bg-accent-strong text-accent-ink rounded-xl text-xs font-mono font-medium transition-smooth disabled:opacity-50 disabled:pointer-events-none"
          >
            Run
          </button>
        </.form>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # F10: Collapsible Reasoning / Thinking Trace (<.thinking_trace>)
  # ============================================================================

  defp workspace_lock_value(nil, _key), do: nil

  defp workspace_lock_value(lock, key) when is_map(lock) do
    Map.get(lock, key) || Map.get(lock, Atom.to_string(key))
  end

  defp workspace_lock_label(lock) do
    cond do
      workspace_lock_value(lock, :run_id) -> "a coding run"
      workspace_lock_value(lock, :session_id) -> "another session"
      true -> "another task"
    end
  end

  @doc """
  Renders a collapsible disclosure card for LLM chain-of-thought reasoning deltas with latency metrics and markdown formatting.
  Delegates to `IexCodeWeb.ThinkingTrace.thinking_trace/1`.
  """
  attr :id, :string, default: nil
  attr :message_id, :any, default: nil
  attr :reasoning, :string, default: nil
  attr :active, :boolean, default: false
  attr :duration_ms, :any, default: nil
  attr :tokens, :any, default: nil

  def thinking_trace(assigns) do
    IexCodeWeb.ThinkingTrace.thinking_trace(assigns)
  end

  # ============================================================================
  # F11: Markdown & Code Block Formatter (<.markdown_content>)
  # ============================================================================

  @doc """
  Renders markdown text with formatted code blocks, bold/italics, bullet points, headers, and code copy buttons.
  """
  attr :content, :string, required: true
  attr :id, :string, default: nil
  attr :message_id, :any, default: nil

  def markdown_content(assigns) do
    # Separate <think> blocks if present in content
    {reasoning, main_body} = extract_think_blocks(assigns.content)
    chunks = parse_markdown_chunks(main_body)
    assigns = assign(assigns, reasoning: reasoning, chunks: chunks)

    ~H"""
    <div id={@id} class="markdown-body orbital-markdown space-y-2">
      <%= if @reasoning do %>
        <.thinking_trace
          id={
            cond do
              @id -> "#{@id}-thinking-trace"
              @message_id -> "thinking-trace-inline-#{@message_id}"
              true -> nil
            end
          }
          reasoning={@reasoning}
        />
      <% end %>
      <div class="space-y-2.5 font-sans text-sm leading-relaxed text-muted">
        <%= for chunk <- @chunks do %>
          <%= case chunk do %>
            <% {:text, text} -> %>
              <div class="whitespace-pre-wrap">
                {text}
              </div>
            <% {:code, lang, code} -> %>
              <div class="orbital-code-block rounded-xl border border-line bg-inset overflow-hidden my-2.5">
                <div class="flex items-center justify-between px-3 py-1.5 bg-raised border-b border-line text-xs font-mono text-muted">
                  <span class="text-accent font-bold uppercase tracking-wider text-[11px]">{lang}</span>
                  <div class="flex items-center gap-1.5">
                    <button
                      type="button"
                      phx-click="insert_code_to_editor"
                      phx-value-code={code}
                      class="flex items-center gap-1 text-[11px] font-mono px-2 py-0.5 rounded bg-success/20 hover:bg-success/40 text-success border border-success/30 transition-smooth"
                      title="Insert into active editor buffer"
                    >
                      <.icon name="hero-arrow-down-tray" class="w-3.5 h-3.5" />
                      <span>Insert into Editor</span>
                    </button>
                    <button
                      type="button"
                      phx-hook="CodeCopy"
                      data-code={code}
                      id={"copy-code-" <> to_string(:erlang.phash2({lang, code}))}
                      class="flex items-center gap-1 text-[11px] font-mono px-2 py-0.5 rounded bg-raised hover:bg-raised text-muted transition-smooth"
                      title="Copy code"
                    >
                      <.icon name="hero-clipboard" class="w-3.5 h-3.5" />
                      <span>Copy</span>
                    </button>
                  </div>
                </div>
                <pre class="p-3 font-mono text-xs text-muted overflow-x-auto selection:bg-accent/10 leading-normal"><code>{code}</code></pre>
              </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp parse_markdown_chunks(text) when is_binary(text) do
    regex = ~r/```([a-zA-Z0-9_\-\.\+\#]*)\r?\n(.*?)```/s

    case Regex.scan(regex, text, return: :index) do
      [] ->
        if text != "", do: [{:text, text}], else: []

      matches ->
        {chunks, last_idx} =
          Enum.reduce(matches, {[], 0}, fn
            [{start, len}, {lang_start, lang_len}, {code_start, code_len}], {acc, prev} ->
              before_text =
                if start > prev do
                  String.slice(text, prev, start - prev)
                else
                  nil
                end

              lang =
                if lang_len > 0 do
                  String.slice(text, lang_start, lang_len) |> String.trim()
                else
                  "code"
                end

              code = String.slice(text, code_start, code_len) |> String.trim_trailing()

              acc =
                if before_text && before_text != "" do
                  [{:text, before_text} | acc]
                else
                  acc
                end

              acc = [{:code, if(lang == "", do: "code", else: lang), code} | acc]
              {acc, start + len}
          end)

        remaining = String.slice(text, last_idx..-1)

        final_chunks =
          if remaining && remaining != "" do
            [{:text, remaining} | chunks]
          else
            chunks
          end

        Enum.reverse(final_chunks)
    end
  end

  defp parse_markdown_chunks(_), do: []

  defp extract_think_blocks(text) when is_binary(text) do
    case Regex.run(~r/<think>(.*?)<\/think>/s, text) do
      [full_match, think_content] ->
        remaining = String.replace(text, full_match, "") |> String.trim()
        {String.trim(think_content), remaining}

      _ ->
        {nil, text}
    end
  end

  defp extract_think_blocks(other), do: {nil, to_string(other || "")}

  # ============================================================================
  # ANSI Escape Code to HTML Color Parser
  # ============================================================================

  @doc """
  Converts ANSI SGR escape codes into sanitized styled HTML spans with Tailwind CSS colors.
  """
  def ansi_to_html(raw_terminal_text) when is_binary(raw_terminal_text) do
    raw_terminal_text
    |> html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> parse_ansi_colors()
    |> raw()
  end

  def ansi_to_html(nil), do: raw("")

  defp parse_ansi_colors(text) do
    text
    # 24-bit TrueColor foreground: \e[38;2;R;G;Bm
    |> then(fn s ->
      Regex.replace(~r/\e\[38;2;(\d+);(\d+);(\d+)m/, s, fn _, r, g, b ->
        "<span style=\"color: rgb(#{r},#{g},#{b});\">"
      end)
    end)
    # 24-bit TrueColor background: \e[48;2;R;G;Bm
    |> then(fn s ->
      Regex.replace(~r/\e\[48;2;(\d+);(\d+);(\d+)m/, s, fn _, r, g, b ->
        "<span style=\"background-color: rgb(#{r},#{g},#{b});\">"
      end)
    end)
    # Compound SGR sequences (e.g. \e[1;31m, \e[1;32;40m)
    |> String.replace("\e[1;31m", "<span class=\"font-bold text-rose-400\">")
    |> String.replace("\e[1;32m", "<span class=\"font-bold text-emerald-400\">")
    |> String.replace("\e[1;33m", "<span class=\"font-bold text-amber-400\">")
    |> String.replace("\e[1;34m", "<span class=\"font-bold text-sky-400\">")
    |> String.replace("\e[1;35m", "<span class=\"font-bold text-purple-400\">")
    |> String.replace("\e[1;36m", "<span class=\"font-bold text-cyan-400\">")
    # Standard colors
    |> String.replace("\e[31m", "<span class=\"text-rose-400 font-medium\">")
    |> String.replace("\e[32m", "<span class=\"text-emerald-400 font-medium\">")
    |> String.replace("\e[33m", "<span class=\"text-amber-400 font-medium\">")
    |> String.replace("\e[34m", "<span class=\"text-sky-400 font-medium\">")
    |> String.replace("\e[35m", "<span class=\"text-purple-400 font-medium\">")
    |> String.replace("\e[36m", "<span class=\"text-cyan-400 font-medium\">")
    |> String.replace("\e[37m", "<span class=\"text-muted font-medium\">")
    |> String.replace("\e[90m", "<span class=\"text-subtle font-medium\">")
    |> String.replace("\e[1m", "<span class=\"font-bold text-white\">")
    |> String.replace("\e[0m", "</span>")
    |> String.replace("\e[m", "</span>")
    # Clean any remaining control sequences / cursor movements
    |> String.replace(~r/\e\[[?0-9;]*[a-zA-Z]/, "")
    |> String.replace(~r/\e\[[0-9;]*[HfABCDsuJK]/, "")
    |> String.replace(~r/\e[\(\)][0-9A-Za-z]/, "")
    |> String.replace(~r/\e\][^\a\e]*(\a|\e\\)/, "")
    |> String.replace(~r/\e(\[[\d;]*|\][^\a\e]*|\([A-Z]|\[\?[0-9]+[a-zA-Z])?/, "")
    |> String.replace("\e", "")
  end

  # ============================================================================
  # M2: Global Command Palette (Cmd+K)
  # ============================================================================

  @doc """
  Renders the global Command Palette modal.
  """
  attr :show, :boolean, default: false
  attr :query, :string, default: ""
  attr :category, :string, default: "all"
  attr :results, :list, default: []
  attr :selected_index, :integer, default: 0

  def command_palette(assigns) do
    selected_item = Enum.at(assigns.results, assigns.selected_index)

    assigns =
      assigns
      |> assign(:selected_item, selected_item)
      |> assign(:search_form, to_form(%{"query" => assigns.query}))

    ~H"""
    <div id="command-palette-controller" phx-hook="CommandPalette" class="contents">
      <%= if @show do %>
        <div
          id="command-palette-modal"
          class="orbital-overlay fixed inset-0 z-50 flex items-start justify-center pt-[8vh] px-4 bg-black/60 backdrop-blur-md transition-opacity"
        >
          <%!-- Backdrop click dismiss --%>
          <div class="fixed inset-0" phx-click="close_command_palette" aria-hidden="true"></div>

          <%!-- Palette Dialog Window (Split Pane) --%>
          <div
            id="command-palette-dialog"
            role="dialog"
            aria-modal="true"
            aria-labelledby="command-palette-title"
            aria-describedby="command-palette-description"
            tabindex="-1"
            class="orbital-panel orbital-command-palette relative w-full max-w-5xl bg-surface border border-line rounded-[20px] overflow-hidden flex flex-col max-h-[82vh] z-10 animate-scale-in"
            phx-click-away="close_command_palette"
          >
            <h2 id="command-palette-title" class="sr-only">Command palette</h2>
            <p id="command-palette-description" class="sr-only">
              Find a command, file, model, or workspace view.
            </p>

            <%!-- Search Header Input --%>
            <div class="flex items-center px-4 py-3 border-b border-line bg-raised/90 gap-3">
              <.icon name="hero-magnifying-glass" class="w-5 h-5 text-accent shrink-0" />
              <.form
                for={@search_form}
                id="command-palette-form"
                phx-change="command_palette_search"
                phx-submit="command_palette_execute_selected"
                class="flex-1 [&>div]:mb-0"
              >
                <.input
                  id="command-palette-input"
                  type="text"
                  field={@search_form[:query]}
                  role="combobox"
                  aria-label="Search command palette"
                  aria-autocomplete="list"
                  aria-expanded="true"
                  aria-controls="command-palette-results"
                  aria-activedescendant={
                    if(@results == [], do: nil, else: "palette-item-#{@selected_index}")
                  }
                  phx-debounce="80"
                  autocomplete="off"
                  spellcheck="false"
                  placeholder="Search commands, files, and models…"
                  class="w-full bg-transparent border-0 text-content placeholder:text-subtle font-sans text-sm focus:outline-none focus:ring-0 p-0"
                />
              </.form>
              <button
                id="command-palette-close"
                type="button"
                phx-click="close_command_palette"
                aria-label="Close command palette"
                class="px-2 py-0.5 text-[11px] font-mono font-medium text-muted bg-raised border border-line rounded-md hover:text-content hover:border-subtle transition-smooth"
              >
                ESC
              </button>
            </div>

            <%!-- Category Filter Pills (All 9 categories) --%>
            <div class="flex items-center gap-1.5 px-4 py-2 border-b border-line bg-inset overflow-x-auto font-mono text-xs scrollbar-none">
              <%= for {cat, label} <- [
                {"all", "All"},
                {"actions", "Actions"},
                {"swarms", "Swarms"},
                {"files", "Files"},
                {"models", "Models"},
                {"branches", "Branches"},
                {"terminal", "Terminal"},
                {"views", "Views"},
                {"sessions", "Sessions"}
              ] do %>
                <button
                  type="button"
                  phx-click="command_palette_set_category"
                  phx-value-category={cat}
                  aria-pressed={to_string(@category == cat)}
                  class={[
                    "px-2.5 py-1 rounded-lg transition-smooth font-medium text-[11px] shrink-0 flex items-center gap-1.5",
                    @category == cat &&
                      "bg-accent/10 text-accent border border-accent/25 font-semibold",
                    @category != cat &&
                      "text-muted hover:text-content hover:bg-raised border border-transparent"
                  ]}
                >
                  <span>{label}</span>
                </button>
              <% end %>
            </div>

            <%!-- Split-Pane Main Container --%>
            <div class="flex-1 flex min-h-[min(26rem,50dvh)] max-h-[60dvh] overflow-hidden divide-x divide-line">
              <%!-- Left Pane: Results List (w-7/12) --%>
              <div
                id="command-palette-results"
                role="listbox"
                aria-label="Command palette results"
                class="w-full sm:w-7/12 flex flex-col min-w-0 overflow-y-auto p-2 space-y-1 font-sans text-sm"
              >
                <%= if @results == [] do %>
                  <div class="py-16 text-center text-subtle font-mono text-xs">
                    <.icon name="hero-magnifying-glass" class="w-10 h-10 text-subtle mx-auto mb-3" />
                    <p class="text-muted font-medium text-sm">No results found for "{@query}"</p>
                    <p class="text-[11px] text-subtle mt-1">
                      Try searching with prefixes: <span class="text-accent">&gt;</span>
                      actions, <span class="text-warning">#</span>
                      files, <span class="text-accent">@</span>
                      swarms, <span class="text-info">$</span>
                      models, <span class="text-success">/</span>
                      branches, <span class="text-warning">!</span>
                      terminal
                    </p>
                  </div>
                <% else %>
                  <%= for {item, idx} <- Enum.with_index(@results) do %>
                    <% is_selected = idx == @selected_index %>
                    <button
                      type="button"
                      id={"palette-item-#{idx}"}
                      role="option"
                      aria-selected={to_string(is_selected)}
                      tabindex="-1"
                      phx-click="command_palette_select_item"
                      phx-value-index={to_string(idx)}
                      class={[
                        "w-full flex items-center justify-between p-2.5 rounded-xl text-left transition-smooth group",
                        is_selected &&
                          "bg-accent/10 text-content border border-accent/25 font-medium",
                        !is_selected && "hover:bg-raised text-muted border border-transparent"
                      ]}
                    >
                      <div class="flex items-center gap-3 truncate min-w-0">
                        <div class={[
                          "w-7 h-7 rounded-lg flex items-center justify-center shrink-0 border",
                          item.category == :action &&
                            "bg-accent/10 text-accent border-accent/30",
                          item.category == :view && "bg-accent/10 text-accent border-accent/30",
                          item.category == :file &&
                            "bg-warning/10 text-warning border-warning/30",
                          item.category == :session &&
                            "bg-success/10 text-success border-success/30",
                          item.category == :swarm &&
                            "bg-accent/10 text-accent border-accent/30",
                          item.category == :model && "bg-info/10 text-info border-info/30",
                          item.category == :branch &&
                            "bg-success/10 text-success border-success/30",
                          item.category == :terminal &&
                            "bg-warning/10 text-warning border-warning/30"
                        ]}>
                          <.icon name={item.icon || "hero-cube"} class="w-4 h-4" />
                        </div>
                        <div class="truncate min-w-0">
                          <div class="font-medium text-muted group-hover:text-content truncate flex items-center gap-2">
                            <span class="truncate">{item.title}</span>
                            <span class={[
                              "text-[10px] uppercase font-mono px-1.5 py-0.5 rounded border shrink-0",
                              item.category == :action &&
                                "bg-accent/10 text-accent border-accent/40",
                              item.category == :view &&
                                "bg-accent/10 text-accent border-accent/40",
                              item.category == :file &&
                                "bg-warning/10 text-warning border-warning/40",
                              item.category == :session &&
                                "bg-success/10 text-success border-success/40",
                              item.category == :swarm &&
                                "bg-accent/10 text-accent border-accent/40",
                              item.category == :model &&
                                "bg-info/10 text-info border-info/40",
                              item.category == :branch &&
                                "bg-success/10 text-success border-success/40",
                              item.category == :terminal &&
                                "bg-warning/10 text-warning border-warning/40"
                            ]}>
                              {to_string(item.category)}
                            </span>
                          </div>
                          <div class="text-[11px] text-subtle font-mono truncate">
                            {item.subtitle}
                          </div>
                        </div>
                      </div>

                      <%= if Map.get(item, :shortcut) && item.shortcut != "" do %>
                        <span class="px-2 py-0.5 text-[10px] font-mono text-muted bg-raised border border-line rounded shrink-0 ml-2">
                          {item.shortcut}
                        </span>
                      <% end %>
                    </button>
                  <% end %>
                <% end %>
              </div>

              <%!-- Right Pane: Dynamic Rich Preview Card (w-5/12) --%>
              <div
                id="command-palette-preview"
                class="hidden sm:flex w-5/12 flex-col min-w-0 overflow-y-auto p-4 bg-inset/90 font-sans"
              >
                <%= if @selected_item do %>
                  <% preview = Map.get(@selected_item, :preview, %{}) %>
                  <%= case @selected_item.category do %>
                    <% :file -> %>
                      <div id="palette-preview-file" class="space-y-4">
                        <div class="flex items-start gap-3">
                          <div class="w-10 h-10 rounded-xl bg-warning/10 border border-warning/30 text-warning flex items-center justify-center shrink-0">
                            <.icon name={@selected_item.icon || "hero-document"} class="w-5 h-5" />
                          </div>
                          <div class="min-w-0">
                            <h3 class="font-semibold text-content text-sm truncate">
                              {Map.get(preview, :filename, @selected_item.title)}
                            </h3>
                            <p class="text-[11px] font-mono text-muted truncate">
                              {Map.get(preview, :path, @selected_item.subtitle)}
                            </p>
                          </div>
                        </div>

                        <div class="flex flex-wrap gap-2 font-mono text-xs">
                          <span class="px-2 py-1 rounded-lg bg-raised border border-line text-warning">
                            {Map.get(preview, :syntax, "Plain Text")}
                          </span>
                          <span class="px-2 py-1 rounded-lg bg-raised border border-line text-muted">
                            {format_palette_bytes(Map.get(preview, :size, 0))}
                          </span>
                          <span class="px-2 py-1 rounded-lg bg-raised border border-line text-muted">
                            {Map.get(preview, :lines, 0)} lines
                          </span>
                        </div>

                        <div class="rounded-xl border border-line bg-raised overflow-hidden">
                          <div class="px-3 py-1.5 border-b border-line text-[10px] font-mono text-muted flex items-center justify-between">
                            <span>Syntax Preview</span>
                            <span>{Map.get(preview, :ext, "")}</span>
                          </div>
                          <div class="p-3 font-mono text-[11px] text-muted overflow-x-auto max-h-[220px]">
                            <%= if Map.get(preview, :preview_lines, []) != [] do %>
                              <pre phx-no-curly-interpolation class="space-y-0.5 leading-relaxed"><%= for {num, line} <- preview.preview_lines do %><div class="flex gap-3"><span class="text-subtle select-none text-right w-6 shrink-0"><%= num %></span><span class="text-muted"><%= line %></span></div><% end %></pre>
                            <% else %>
                              <div class="py-6 text-center text-subtle text-xs italic">
                                File content preview unavailable or empty
                              </div>
                            <% end %>
                          </div>
                        </div>

                        <div class="text-[11px] text-subtle font-mono">
                          Press
                          <kbd class="px-1.5 py-0.5 bg-raised border border-line rounded text-muted">↵</kbd>
                          to open buffer in editor
                        </div>
                      </div>
                    <% :swarm -> %>
                      <div id="palette-preview-swarm" class="space-y-4">
                        <div class="flex items-start gap-3">
                          <div class="w-10 h-10 rounded-xl bg-accent/10 border border-accent/30 text-accent flex items-center justify-center shrink-0">
                            <.icon name="hero-sparkles" class="w-5 h-5" />
                          </div>
                          <div class="min-w-0">
                            <h3 class="font-semibold text-content text-sm truncate">
                              {Map.get(preview, :objective, @selected_item.title)}
                            </h3>
                            <div class="flex items-center gap-2 mt-1">
                              <span class="px-2 py-0.5 text-[10px] uppercase font-mono rounded bg-accent/10 text-accent border border-accent/40">
                                {Map.get(preview, :mode, "swarm")}
                              </span>
                              <span class={[
                                "px-2 py-0.5 text-[10px] uppercase font-mono rounded border",
                                Map.get(preview, :status) == "running" &&
                                  "bg-success/10 text-success border-success/40",
                                Map.get(preview, :status) == "completed" &&
                                  "bg-info/10 text-info border-info/40",
                                Map.get(preview, :status) not in ["running", "completed"] &&
                                  "bg-surface/60 text-muted border-line/40"
                              ]}>
                                {Map.get(preview, :status, "queued")}
                              </span>
                            </div>
                          </div>
                        </div>

                        <div class="grid grid-cols-2 gap-2 font-mono text-xs">
                          <div class="p-2.5 rounded-xl bg-raised border border-line">
                            <div class="text-[10px] text-subtle uppercase">Active Agents</div>
                            <div class="text-sm font-semibold text-accent mt-0.5">
                              {Map.get(preview, :active_agents, 4)} Workers
                            </div>
                          </div>
                          <div class="p-2.5 rounded-xl bg-raised border border-line">
                            <div class="text-[10px] text-subtle uppercase">Tokens Consumed</div>
                            <div class="text-sm font-semibold text-muted mt-0.5">
                              {Map.get(preview, :tokens, 0)}
                            </div>
                          </div>
                        </div>

                        <div class="p-3 rounded-xl bg-raised border border-line space-y-1.5">
                          <div class="flex justify-between text-xs font-mono">
                            <span class="text-muted">Run Progress</span>
                            <span class="text-accent font-semibold">{Map.get(
                              preview,
                              :progress,
                              0
                            )}%</span>
                          </div>
                          <div class="w-full h-1.5 bg-surface rounded-full overflow-hidden">
                            <div
                              class="h-full bg-accent rounded-full transition-all duration-300"
                              style={"width: #{Map.get(preview, :progress, 0)}%;"}
                            >
                            </div>
                          </div>
                        </div>

                        <div class="text-[11px] text-subtle font-mono">
                          Press
                          <kbd class="px-1.5 py-0.5 bg-raised border border-line rounded text-muted">↵</kbd>
                          to jump to Swarm Telemetry canvas
                        </div>
                      </div>
                    <% :model -> %>
                      <div id="palette-preview-model" class="space-y-4">
                        <div class="flex items-start gap-3">
                          <div class="w-10 h-10 rounded-xl bg-info/10 border border-info/30 text-info flex items-center justify-center shrink-0">
                            <.icon name="hero-cpu-chip" class="w-5 h-5" />
                          </div>
                          <div class="min-w-0">
                            <h3 class="font-semibold text-content text-sm truncate">
                              {Map.get(preview, :name, @selected_item.title)}
                            </h3>
                            <p class="text-[11px] font-mono text-muted truncate">
                              Provider: {Map.get(preview, :provider, "anthropic")}
                            </p>
                          </div>
                        </div>

                        <div class="flex flex-wrap gap-2 font-mono text-xs">
                          <span class={[
                            "px-2 py-1 rounded-lg border font-semibold",
                            Map.get(preview, :local?) &&
                              "bg-success/10 text-success border-success/40",
                            !Map.get(preview, :local?) &&
                              "bg-info/10 text-info border-info/40"
                          ]}>
                            {if Map.get(preview, :local?), do: "Local Offline", else: "Cloud Endpoint"}
                          </span>
                          <span class="px-2 py-1 rounded-lg bg-raised border border-line text-success flex items-center gap-1.5">
                            <span class="w-1.5 h-1.5 rounded-full bg-success animate-pulse"></span>
                            Online
                          </span>
                        </div>

                        <div class="p-3 rounded-xl bg-raised border border-line space-y-1">
                          <div class="text-[10px] font-mono text-subtle uppercase">
                            API Gateway / Endpoint
                          </div>
                          <div class="text-xs font-mono text-muted truncate">
                            {Map.get(preview, :endpoint, "api.anthropic.com")}
                          </div>
                        </div>

                        <div class="text-[11px] text-subtle font-mono">
                          Press
                          <kbd class="px-1.5 py-0.5 bg-raised border border-line rounded text-muted">↵</kbd>
                          to set as active session model
                        </div>
                      </div>
                    <% :branch -> %>
                      <div id="palette-preview-branch" class="space-y-4">
                        <div class="flex items-start gap-3">
                          <div class="w-10 h-10 rounded-xl bg-success/10 border border-success/30 text-success flex items-center justify-center shrink-0">
                            <.icon name="hero-code-bracket" class="w-5 h-5" />
                          </div>
                          <div class="min-w-0">
                            <h3 class="font-semibold text-content text-sm truncate">
                              {Map.get(preview, :name, @selected_item.title)}
                            </h3>
                            <p class="text-[11px] font-mono text-muted">
                              Git Working Branch
                            </p>
                          </div>
                        </div>

                        <div class="flex flex-wrap gap-2 font-mono text-xs">
                          <%= if Map.get(preview, :current?) do %>
                            <span class="px-2 py-1 rounded-lg bg-success/10 text-success border border-success/40 font-semibold flex items-center gap-1.5">
                              <span class="w-1.5 h-1.5 rounded-full bg-success"></span> Current HEAD
                            </span>
                          <% else %>
                            <span class="px-2 py-1 rounded-lg bg-raised border border-line text-muted">
                              Available Branch
                            </span>
                          <% end %>
                          <span class="px-2 py-1 rounded-lg bg-raised border border-line text-muted">
                            Upstream: {Map.get(preview, :upstream) || "local only"}
                          </span>
                        </div>

                        <div class="p-3 rounded-xl bg-raised border border-line space-y-1">
                          <div class="text-[10px] font-mono text-subtle uppercase">
                            Head Pointer
                          </div>
                          <div class="text-xs font-mono text-accent">
                            refs/heads/{Map.get(preview, :name, @selected_item.title)}
                          </div>
                        </div>

                        <div class="text-[11px] text-subtle font-mono">
                          Press
                          <kbd class="px-1.5 py-0.5 bg-raised border border-line rounded text-muted">↵</kbd>
                          to checkout and switch to this branch
                        </div>
                      </div>
                    <% :terminal -> %>
                      <div id="palette-preview-terminal" class="space-y-4">
                        <div class="flex items-start gap-3">
                          <div class="w-10 h-10 rounded-xl bg-warning/10 border border-warning/30 text-warning flex items-center justify-center shrink-0">
                            <.icon name="hero-command-line" class="w-5 h-5" />
                          </div>
                          <div class="min-w-0">
                            <h3 class="font-semibold text-content text-sm truncate font-mono">
                              {Map.get(preview, :command, @selected_item.title)}
                            </h3>
                            <p class="text-[11px] text-muted">
                              {Map.get(preview, :description, @selected_item.subtitle)}
                            </p>
                          </div>
                        </div>

                        <div class="p-3 rounded-xl bg-raised border border-line space-y-1 font-mono">
                          <div class="text-[10px] text-subtle uppercase">
                            Target Directory (CWD)
                          </div>
                          <div class="text-xs text-warning truncate">
                            {Map.get(preview, :directory, ".")}
                          </div>
                        </div>

                        <div class="p-3 rounded-xl bg-raised border border-line space-y-1 font-mono">
                          <div class="text-[10px] text-subtle uppercase">Command Execution</div>
                          <div class="text-xs text-muted">
                            $
                            <span class="text-content font-semibold">{Map.get(
                              preview,
                              :command,
                              @selected_item.title
                            )}</span>
                          </div>
                        </div>

                        <div class="text-[11px] text-subtle font-mono">
                          Press
                          <kbd class="px-1.5 py-0.5 bg-raised border border-line rounded text-muted">↵</kbd>
                          to execute command in terminal shell
                        </div>
                      </div>
                    <% :action -> %>
                      <div id="palette-preview-action" class="space-y-4">
                        <div class="flex items-start gap-3">
                          <div class="w-10 h-10 rounded-xl bg-accent/10 border border-accent/30 text-accent flex items-center justify-center shrink-0">
                            <.icon name={@selected_item.icon || "hero-bolt"} class="w-5 h-5" />
                          </div>
                          <div class="min-w-0">
                            <h3 class="font-semibold text-content text-sm truncate">
                              {@selected_item.title}
                            </h3>
                            <p class="text-[11px] text-muted">
                              {Map.get(preview, :description, @selected_item.subtitle)}
                            </p>
                          </div>
                        </div>

                        <div class="flex flex-wrap gap-2 font-mono text-xs">
                          <%= if Map.get(preview, :shortcut) && preview.shortcut != "" do %>
                            <span class="px-2 py-1 rounded-lg bg-accent/10 text-accent border border-accent/40 font-semibold">
                              Shortcut: {preview.shortcut}
                            </span>
                          <% end %>
                          <%= if Map.get(preview, :target_tab) && preview.target_tab != "" do %>
                            <span class="px-2 py-1 rounded-lg bg-raised border border-line text-accent">
                              Target: {preview.target_tab}
                            </span>
                          <% end %>
                        </div>

                        <div class="p-3 rounded-xl bg-raised border border-line space-y-1 font-mono">
                          <div class="text-[10px] text-subtle uppercase">Action Trigger</div>
                          <div class="text-xs text-accent">
                            handle_event("{Map.get(preview, :event, @selected_item.id)}")
                          </div>
                        </div>

                        <div class="text-[11px] text-subtle font-mono">
                          Press
                          <kbd class="px-1.5 py-0.5 bg-raised border border-line rounded text-muted">↵</kbd>
                          to execute this action
                        </div>
                      </div>
                    <% :view -> %>
                      <div id="palette-preview-view" class="space-y-4">
                        <div class="flex items-start gap-3">
                          <div class="w-10 h-10 rounded-xl bg-accent/10 border border-accent/30 text-accent flex items-center justify-center shrink-0">
                            <.icon name={@selected_item.icon || "hero-squares-2x2"} class="w-5 h-5" />
                          </div>
                          <div class="min-w-0">
                            <h3 class="font-semibold text-content text-sm truncate">
                              {@selected_item.title}
                            </h3>
                            <p class="text-[11px] text-muted">
                              {Map.get(preview, :description, @selected_item.subtitle)}
                            </p>
                          </div>
                        </div>

                        <div class="p-3 rounded-xl bg-raised border border-line space-y-1 font-mono">
                          <div class="text-[10px] text-subtle uppercase">
                            Workspace Tab Destination
                          </div>
                          <div class="text-xs text-accent">
                            active_tab: "{Map.get(preview, :target_tab, @selected_item[:tab])}"
                          </div>
                        </div>

                        <div class="text-[11px] text-subtle font-mono">
                          Press
                          <kbd class="px-1.5 py-0.5 bg-raised border border-line rounded text-muted">↵</kbd>
                          to switch directly to this workspace view
                        </div>
                      </div>
                    <% :session -> %>
                      <div id="palette-preview-session" class="space-y-4">
                        <div class="flex items-start gap-3">
                          <div class="w-10 h-10 rounded-xl bg-success/10 border border-success/30 text-success flex items-center justify-center shrink-0">
                            <.icon name="hero-document-text" class="w-5 h-5" />
                          </div>
                          <div class="min-w-0">
                            <h3 class="font-semibold text-content text-sm truncate">
                              {Map.get(preview, :title, @selected_item.title)}
                            </h3>
                            <p class="text-[11px] font-mono text-muted">
                              Session ID: {Map.get(preview, :session_id, @selected_item[:session_id])}
                            </p>
                          </div>
                        </div>

                        <div class="grid grid-cols-2 gap-2 font-mono text-xs">
                          <div class="p-2.5 rounded-xl bg-raised border border-line">
                            <div class="text-[10px] text-subtle uppercase">Assigned Model</div>
                            <div class="text-xs font-semibold text-success mt-0.5 truncate">
                              {Map.get(preview, :model, "default")}
                            </div>
                          </div>
                          <div class="p-2.5 rounded-xl bg-raised border border-line">
                            <div class="text-[10px] text-subtle uppercase">Messages</div>
                            <div class="text-xs font-semibold text-muted mt-0.5">
                              {Map.get(preview, :message_count, 0)} items
                            </div>
                          </div>
                        </div>

                        <div class="p-3 rounded-xl bg-raised border border-line space-y-1 font-mono">
                          <div class="text-[10px] text-subtle uppercase">Last Activity</div>
                          <div class="text-xs text-muted">
                            {Map.get(preview, :updated_at, @selected_item.subtitle)}
                          </div>
                        </div>

                        <div class="text-[11px] text-subtle font-mono">
                          Press
                          <kbd class="px-1.5 py-0.5 bg-raised border border-line rounded text-muted">↵</kbd>
                          to load session dialogue
                        </div>
                      </div>
                    <% _ -> %>
                      <div
                        id="palette-preview-empty"
                        class="py-20 text-center text-subtle font-mono text-xs"
                      >
                        <.icon name="hero-sparkles" class="w-8 h-8 text-subtle mx-auto mb-2" />
                        <p>No preview metadata available for this item</p>
                      </div>
                  <% end %>
                <% else %>
                  <div
                    id="palette-preview-empty"
                    class="py-20 text-center text-subtle font-mono text-xs"
                  >
                    <.icon name="hero-cursor-arrow-rays" class="w-8 h-8 text-subtle mx-auto mb-2" />
                    <p>Select an item to view preview card</p>
                  </div>
                <% end %>
              </div>
            </div>

            <%!-- Footer Keyboard Navigation Helper --%>
            <div class="px-4 py-2 border-t border-line bg-inset flex flex-wrap items-center justify-between gap-2 text-[11px] font-mono text-subtle">
              <div class="flex items-center gap-2.5">
                <span><kbd class="px-1.5 py-0.5 bg-raised border border-line rounded text-muted">↑↓</kbd>
                Navigate</span>
                <span><kbd class="px-1.5 py-0.5 bg-raised border border-line rounded text-muted">↵</kbd>
                Select</span>
                <span><kbd class="px-1.5 py-0.5 bg-raised border border-line rounded text-muted">esc</kbd>
                Close</span>
                <span><kbd class="px-1.5 py-0.5 bg-raised border border-line rounded text-muted">Cmd+K</kbd>
                Toggle</span>
                <span><kbd class="px-1.5 py-0.5 bg-raised border border-line rounded text-muted">Cmd+N</kbd>
                Sidebar</span>
                <span><kbd class="px-1.5 py-0.5 bg-raised border border-line rounded text-muted">Cmd+J</kbd>
                Terminal</span>
              </div>
              <div class="text-[10px] text-subtle flex items-center gap-1.5">
                <span>Prefixes:</span>
                <span class="text-accent">&gt; actions</span>
                <span class="text-warning"># files</span>
                <span class="text-accent">@ swarms</span>
                <span class="text-info">$ models</span>
                <span class="text-success">/ branches</span>
                <span class="text-warning">! terminal</span>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp format_palette_bytes(nil), do: "0 B"
  defp format_palette_bytes(0), do: "0 B"
  defp format_palette_bytes(bytes) when bytes < 1024, do: "#{bytes} B"

  defp format_palette_bytes(bytes) when bytes < 1024 * 1024,
    do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_palette_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  # ============================================================================
  # M3: Visual Test Runner & 1-Click AutoFix Studio
  # ============================================================================

  @doc """
  Renders the Visual Test Studio panel with toolbar triggers, real-time progress,
  metrics strip, and expandable failure cards with 1-click AutoFix.
  """
  attr :test_runner_status, :atom, default: :idle
  attr :test_runner_progress_pct, :integer, default: 0
  attr :test_runner_progress_msg, :string, default: ""
  attr :test_runner_result, :any, default: nil
  attr :show_autofix_modal, :boolean, default: false
  attr :autofix_status, :atom, default: :idle
  attr :autofix_target_failure, :any, default: nil
  attr :autofix_diff, :string, default: nil
  attr :autofix_planned_patches, :list, default: []
  attr :autofix_tx_id, :string, default: nil

  def test_runner_panel(assigns) do
    ~H"""
    <div
      id="test-runner-panel"
      class="orbital-panel orbital-test-studio flex-1 flex flex-col h-full bg-inset overflow-hidden"
    >
      <.page_header
        id="test-studio-header"
        title="Visual Test Studio"
        description="Run ExUnit tests, inspect failures, and review fixes."
        icon="hero-beaker"
      >
        <:meta>
          <span class={[
            "px-2 py-0.5 rounded-full text-[10px] font-mono uppercase font-bold border",
            @test_runner_status == :passed &&
              "bg-success/10 text-success border-success/30",
            @test_runner_status == :failed && "bg-danger/10 text-danger border-danger/30",
            @test_runner_status == :running &&
              "bg-accent/10 text-accent border-accent/30 animate-pulse",
            @test_runner_status == :error && "bg-warning/10 text-warning border-warning/30",
            @test_runner_status == :idle && "bg-surface text-muted border-line"
          ]}>
            {to_string(@test_runner_status)}
          </span>
        </:meta>
        <:actions>
          <button
            id="test-studio-run-all"
            type="button"
            phx-click="run_tests"
            phx-value-mode="all"
            disabled={@test_runner_status == :running}
            class="header-control header-control--primary"
          >
            <.icon name="hero-play" class="w-3.5 h-3.5" />
            <span>Run All Tests</span>
          </button>
          <button
            id="test-studio-run-failed"
            type="button"
            phx-click="run_tests"
            phx-value-mode="failed"
            disabled={@test_runner_status == :running}
            class="header-control"
          >
            <.icon name="hero-arrow-path" class="w-3.5 h-3.5" />
            <span>Run Failed</span>
          </button>
          <button
            id="test-studio-run-stale"
            type="button"
            phx-click="run_tests"
            phx-value-mode="stale"
            disabled={@test_runner_status == :running}
            class="header-control"
          >
            <.icon name="hero-bolt" class="w-3.5 h-3.5" />
            <span>Run Stale</span>
          </button>
        </:actions>
      </.page_header>

      <%!-- Real-Time Progress Bar --%>
      <%= if @test_runner_status == :running or (@test_runner_progress_pct > 0 and @test_runner_progress_pct < 100) do %>
        <div class="px-4 py-2 bg-raised border-b border-line flex flex-col gap-1.5">
          <div class="flex items-center justify-between text-xs font-mono text-muted">
            <span class="truncate">{@test_runner_progress_msg}</span>
            <span class="text-accent font-bold">{@test_runner_progress_pct}%</span>
          </div>
          <div class="w-full bg-raised rounded-full h-1.5 overflow-hidden">
            <div
              class="bg-accent h-full rounded-full transition-all duration-300"
              style={"width: #{@test_runner_progress_pct}%"}
            >
            </div>
          </div>
        </div>
      <% end %>

      <%!-- Main Results Area --%>
      <div class="orbital-test-results flex-1 overflow-y-auto p-5 space-y-4 text-xs">
        <%= if @test_runner_result do %>
          <%!-- Metrics Strip --%>
          <div class="orbital-test-metrics grid grid-cols-2 sm:grid-cols-3 md:grid-cols-6">
            <div class="bg-raised border border-line rounded-xl p-3 flex flex-col">
              <span class="text-subtle text-[10px] uppercase font-bold">Total Tests</span>
              <span class="text-lg font-bold text-content mt-1">{@test_runner_result.total}</span>
            </div>
            <div class="bg-raised border border-line rounded-xl p-3 flex flex-col">
              <span class="text-success text-[10px] uppercase font-bold">Passed</span>
              <span class="text-lg font-bold text-success mt-1">{@test_runner_result.passed}</span>
            </div>
            <div class="bg-raised border border-line rounded-xl p-3 flex flex-col">
              <span class="text-danger text-[10px] uppercase font-bold">Failed</span>
              <span class="text-lg font-bold text-danger mt-1">{@test_runner_result.failures_count ||
                length(@test_runner_result.failures)}</span>
            </div>
            <div class="bg-raised border border-line rounded-xl p-3 flex flex-col">
              <span class="text-warning text-[10px] uppercase font-bold">Skipped</span>
              <span class="text-lg font-bold text-warning mt-1">{@test_runner_result.skipped || 0}</span>
            </div>
            <div class="bg-raised border border-line rounded-xl p-3 flex flex-col">
              <span class="text-accent text-[10px] uppercase font-bold">Duration</span>
              <span class="text-lg font-bold text-accent mt-1">{@test_runner_result.duration_s || 0}s</span>
            </div>
            <div class="bg-raised border border-line rounded-xl p-3 flex flex-col">
              <span class="text-accent text-[10px] uppercase font-bold">Seed</span>
              <span class="text-lg font-bold text-accent mt-1">{@test_runner_result.seed || 0}</span>
            </div>
          </div>

          <%!-- Compilation Errors --%>
          <%= if @test_runner_result.compilation_errors != [] do %>
            <div class="space-y-3">
              <h3 class="text-xs font-bold text-danger uppercase tracking-wider flex items-center gap-2">
                <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
                <span>Compilation Errors ({length(@test_runner_result.compilation_errors)})</span>
              </h3>
              <%= for ce <- @test_runner_result.compilation_errors do %>
                <div class="bg-raised border border-danger/40 rounded-xl p-4 space-y-3">
                  <div class="flex items-center justify-between">
                    <div class="flex items-center gap-2">
                      <span class="px-2 py-0.5 bg-danger/20 text-danger rounded font-bold">COMPILE ERROR</span>
                      <span class="text-muted font-semibold">{ce.file}:{ce.line}</span>
                    </div>
                  </div>
                  <pre class="bg-inset p-3 rounded-lg text-danger overflow-x-auto whitespace-pre-wrap">{ce.raw || ce.message}</pre>
                </div>
              <% end %>
            </div>
          <% end %>

          <%!-- Failures List --%>
          <%= if @test_runner_result.failures != [] do %>
            <div class="space-y-3">
              <h3 class="text-xs font-bold text-danger uppercase tracking-wider flex items-center gap-2">
                <.icon name="hero-x-circle" class="w-4 h-4" />
                <span>Test Failures ({length(@test_runner_result.failures)})</span>
              </h3>

              <%= for failure <- @test_runner_result.failures do %>
                <div class="orbital-test-failure bg-surface border border-danger/30 rounded-xl p-4 space-y-3">
                  <%!-- Header --%>
                  <div class="flex flex-wrap items-start justify-between gap-2 border-b border-line pb-3">
                    <div>
                      <div class="flex items-center gap-2">
                        <span class="px-2 py-0.5 rounded bg-danger/20 text-danger font-bold text-[11px]">
                          FAILURE #{failure.index}
                        </span>
                        <span class="font-bold text-content">{failure.test_name}</span>
                      </div>
                      <div class="text-muted mt-1 text-[11px]">
                        <span class="text-accent">{failure.module}</span>
                        · <span class="text-muted">{failure.file}:{failure.line}</span>
                      </div>
                    </div>

                    <div class="flex items-center gap-2">
                      <button
                        type="button"
                        phx-click="autofix_failure"
                        phx-value-index={to_string(failure.index)}
                        class="px-3 py-1 bg-accent/10 hover:bg-accent/20 text-accent border border-accent/40 rounded-lg font-semibold transition-smooth flex items-center gap-1.5 shadow-sm"
                      >
                        <.icon name="hero-sparkles" class="w-3.5 h-3.5 text-warning" />
                        <span>Auto-Fix Failure</span>
                      </button>
                      <button
                        type="button"
                        phx-click="jump_to_symbol"
                        phx-value-path={failure.file}
                        phx-value-line={to_string(failure.line)}
                        class="px-2.5 py-1 bg-raised hover:bg-raised text-muted rounded-lg transition-smooth flex items-center gap-1"
                        title="Open in editor"
                      >
                        <.icon name="hero-arrow-top-right-on-square" class="w-3.5 h-3.5" />
                        <span>Editor</span>
                      </button>
                    </div>
                  </div>

                  <%!-- Failure Message --%>
                  <%= if failure.message && failure.message != "" do %>
                    <div class="p-2.5 bg-inset rounded-lg border border-line text-danger">
                      <span class="text-muted font-bold">Message: </span>
                      <span>{failure.message}</span>
                    </div>
                  <% end %>

                  <%!-- Left vs Right Assertion Diffs --%>
                  <%= if failure.left || failure.right do %>
                    <div class="grid grid-cols-1 md:grid-cols-2 gap-3 font-mono">
                      <div class="p-3 bg-danger/10 border border-danger/30 rounded-lg">
                        <div class="text-danger font-bold text-[10px] uppercase mb-1">
                          Left (Actual)
                        </div>
                        <pre class="text-danger overflow-x-auto whitespace-pre-wrap">{failure.left}</pre>
                      </div>
                      <div class="p-3 bg-success/10 border border-success/30 rounded-lg">
                        <div class="text-success font-bold text-[10px] uppercase mb-1">
                          Right (Expected)
                        </div>
                        <pre class="text-success overflow-x-auto whitespace-pre-wrap">{failure.right}</pre>
                      </div>
                    </div>
                  <% end %>

                  <%!-- Code Snippet --%>
                  <%= if failure.code_snippet && failure.code_snippet != "" do %>
                    <div class="p-3 bg-inset border border-line rounded-lg">
                      <div class="text-muted font-bold text-[10px] uppercase mb-1.5">
                        Code Snippet
                      </div>
                      <pre class="text-muted overflow-x-auto whitespace-pre-wrap">{failure.code_snippet}</pre>
                    </div>
                  <% end %>

                  <%!-- Stacktrace --%>
                  <%= if failure.stacktrace && failure.stacktrace != [] do %>
                    <div class="p-3 bg-inset border border-line rounded-lg space-y-1">
                      <div class="text-muted font-bold text-[10px] uppercase mb-1">Stacktrace</div>
                      <%= for frame <- failure.stacktrace do %>
                        <div class="text-muted text-[11px] truncate">
                          • {if is_binary(frame),
                            do: frame,
                            else: frame.raw || "#{frame.file}:#{frame.line}"}
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>

          <%!-- Clean State --%>
          <%= if @test_runner_result.failures == [] and @test_runner_result.compilation_errors == [] do %>
            <div id="test-studio-success" class="orbital-test-success py-8 text-center text-success">
              <.icon name="hero-check-circle" class="w-12 h-12 mx-auto mb-3 text-success" />
              <p class="text-base font-bold">
                All {@test_runner_result.passed} tests passed
              </p>
              <p class="text-xs text-muted mt-1">
                Ran with seed {@test_runner_result.seed} in {@test_runner_result.duration_s}s
              </p>
            </div>
          <% end %>
        <% else %>
          <.orbital_empty
            id="test-studio-empty"
            title={
              if @test_runner_status == :running,
                do: "Tests are running",
                else: "Ready to verify your work"
            }
            description={
              if @test_runner_status == :running,
                do: "Results and failure details will appear as this test run completes.",
                else:
                  "Run the full suite, retry failures, or check tests affected by your latest changes."
            }
            icon="hero-beaker"
            loading={@test_runner_status == :running}
          />
        <% end %>
      </div>

      <%!-- AutoFix Modal Overlay --%>
      <.autofix_modal
        show={@show_autofix_modal}
        status={@autofix_status}
        failure={@autofix_target_failure}
        diff={@autofix_diff}
        tx_id={@autofix_tx_id}
      />
    </div>
    """
  end

  @doc """
  Renders the 1-Click AutoFix Studio Patch Proposal Modal.
  """
  attr :show, :boolean, default: false
  attr :status, :atom, default: :idle
  attr :failure, :any, default: nil
  attr :diff, :string, default: nil
  attr :tx_id, :string, default: nil

  def autofix_modal(assigns) do
    ~H"""
    <%= if @show do %>
      <div class="orbital-overlay fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/70 backdrop-blur-sm">
        <div class="orbital-panel orbital-autofix relative w-full max-w-3xl bg-surface border border-accent/40 rounded-[20px] overflow-hidden flex flex-col max-h-[85vh] text-xs animate-scale-in">
          <%!-- Header --%>
          <div class="px-5 py-4 border-b border-line bg-raised flex items-center justify-between">
            <div class="flex items-center gap-2.5">
              <.icon name="hero-sparkles" class="w-5 h-5 text-warning" />
              <div>
                <h3 class="text-sm font-bold text-content">AutoFix proposal</h3>
                <p class="text-[11px] text-muted font-normal">
                  Review the proposed changes before applying them.
                </p>
              </div>
            </div>
            <button
              type="button"
              phx-click="close_autofix_modal"
              class="p-1 rounded-lg text-muted hover:text-content hover:bg-raised transition-smooth"
            >
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </button>
          </div>

          <%!-- Body --%>
          <div class="flex-1 overflow-y-auto p-5 space-y-4">
            <%= if @failure do %>
              <div class="p-3 bg-inset border border-line rounded-xl text-muted">
                <span class="text-accent font-bold">Target: </span>
                <span>{Map.get(@failure, :file)}:{Map.get(@failure, :line)}</span>
                <span class="text-subtle mx-2">·</span>
                <span class="text-muted">{Map.get(@failure, :message) ||
                  Map.get(@failure, :test_name)}</span>
              </div>
            <% end %>

            <div>
              <div class="text-muted font-bold text-[11px] uppercase mb-1.5 flex items-center gap-2">
                <.icon name="hero-code-bracket" class="w-4 h-4 text-accent" />
                <span>Unified Diff Proposal</span>
              </div>
              <pre class="p-4 bg-inset border border-line rounded-xl text-muted overflow-x-auto whitespace-pre-wrap font-mono text-xs leading-relaxed max-h-64">{@diff || "No diff generated"}</pre>
            </div>
          </div>

          <%!-- Footer Actions --%>
          <div class="px-5 py-3 border-t border-line bg-raised flex items-center justify-between">
            <div>
              <%= if @tx_id do %>
                <button
                  type="button"
                  phx-click="rollback_autofix"
                  data-confirm="Roll back the applied AutoFix patch?"
                  class="px-3 py-1.5 bg-warning/20 hover:bg-warning/30 text-warning border border-warning/40 rounded-lg font-semibold transition-smooth flex items-center gap-1.5"
                >
                  <.icon name="hero-arrow-uturn-left" class="w-3.5 h-3.5" />
                  <span>Rollback Fix</span>
                </button>
              <% end %>
            </div>

            <div class="flex items-center gap-2">
              <button
                type="button"
                phx-click="close_autofix_modal"
                class="px-3 py-1.5 bg-raised hover:bg-raised text-muted rounded-lg transition-smooth"
              >
                Dismiss
              </button>
              <button
                type="button"
                phx-click="apply_autofix_patch"
                class="px-4 py-1.5 bg-accent hover:bg-accent-strong text-accent-ink rounded-lg font-semibold transition-smooth flex items-center gap-1.5"
              >
                <.icon name="hero-check" class="w-4 h-4" />
                <span>Apply patch</span>
              </button>
            </div>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  # ============================================================================
  # M4: AST Query Explorer & Symbol Navigator
  # ============================================================================

  @doc """
  Renders the AST Query Explorer and Symbol Navigator.
  """
  attr :ast_query, :string, default: ""
  attr :ast_type_filter, :string, default: "all"
  attr :ast_visibility, :string, default: "all"
  attr :ast_results, :list, default: []
  attr :ast_searching?, :boolean, default: false
  attr :ast_total_count, :integer, default: 0

  def ast_explorer(assigns) do
    assigns = assign(assigns, :search_form, to_form(%{"query" => assigns.ast_query}))

    ~H"""
    <div
      id="ast-explorer-panel"
      class="orbital-panel orbital-ast flex-1 flex flex-col h-full bg-inset overflow-hidden text-xs"
    >
      <.page_header
        id="ast-explorer-header"
        title="AST Query Explorer"
        description="Find symbols, inspect their source, and jump to the editor."
        icon="hero-cube-transparent"
      >
        <:actions>
          <div class="text-[11px] text-muted">
            <span>Showing {@ast_total_count} matching symbols</span>
          </div>
        </:actions>
      </.page_header>
      <.page_toolbar id="ast-explorer-toolbar" class="[&_.page-toolbar__controls]:w-full">
        <div class="flex w-full min-w-0 flex-col gap-3">
          <%!-- Search Bar --%>
          <.form
            for={@search_form}
            id="ast-search-form"
            phx-change="search_ast_symbols"
            phx-submit="search_ast_symbols"
            class="relative [&>div]:mb-0"
          >
            <.icon name="hero-magnifying-glass" class="w-4 h-4 text-muted absolute left-3 top-2.5" />
            <.input
              id="ast-search-input"
              type="text"
              field={@search_form[:query]}
              aria-label="Search source symbols"
              phx-debounce="150"
              placeholder="Search a function, module, macro, or spec…"
              class="w-full bg-raised border border-line rounded-xl pl-9 pr-4 py-2 text-content placeholder:text-subtle font-mono text-xs focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/50"
            />
          </.form>

          <%!-- Filter Chips (Type & Visibility) --%>
          <div class="flex flex-wrap items-center justify-between gap-2">
            <%!-- Type Filter Pills --%>
            <div class="flex items-center gap-1.5 overflow-x-auto">
              <%= for {t, label} <- [{"all", "All"}, {"function", "def / defp"}, {"module", "defmodule"}, {"macro", "defmacro"}, {"spec", "@spec"}, {"callback", "@callback"}, {"type", "@type"}, {"doc", "@doc"}] do %>
                <button
                  type="button"
                  phx-click="set_ast_type_filter"
                  id={"ast-type-filter-#{t}"}
                  phx-value-type={t}
                  aria-pressed={@ast_type_filter == t}
                  class={[
                    "px-2.5 py-1 rounded-lg transition-smooth text-[11px] font-medium shrink-0 border",
                    @ast_type_filter == t &&
                      "bg-accent/20 text-accent border-accent/40 font-bold",
                    @ast_type_filter != t &&
                      "bg-raised text-muted hover:text-content border-line"
                  ]}
                >
                  {label}
                </button>
              <% end %>
            </div>

            <%!-- Visibility Pills --%>
            <div class="flex items-center bg-raised p-0.5 rounded-lg border border-line text-[11px]">
              <%= for {v, label} <- [{"all", "All"}, {"public", "Public"}, {"private", "Private"}] do %>
                <button
                  type="button"
                  phx-click="set_ast_visibility"
                  id={"ast-visibility-filter-#{v}"}
                  phx-value-visibility={v}
                  aria-pressed={@ast_visibility == v}
                  class={[
                    "px-2 py-0.5 rounded font-medium transition-smooth",
                    @ast_visibility == v && "bg-raised text-content font-bold",
                    @ast_visibility != v && "text-muted hover:text-content"
                  ]}
                >
                  {label}
                </button>
              <% end %>
            </div>
          </div>
        </div>
      </.page_toolbar>

      <%!-- Symbols Results List --%>
      <div class="orbital-symbol-results flex-1 overflow-y-auto p-5 space-y-3">
        <%= if @ast_results == [] do %>
          <.orbital_empty
            id="ast-explorer-empty"
            title={
              cond do
                @ast_searching? -> "Searching source symbols"
                @ast_query == "" -> "Explore your codebase"
                true -> "No symbols found"
              end
            }
            description={
              if @ast_query == "",
                do: "Search by name, then narrow the results by symbol type and visibility.",
                else: "Try a broader search or adjust the symbol filters above."
            }
            icon="hero-cube-transparent"
            loading={@ast_searching?}
          />
        <% else %>
          <%= for symbol <- @ast_results do %>
            <div class="orbital-symbol-row bg-surface border border-line hover:border-accent/40 rounded-xl p-3.5 space-y-2.5 transition-smooth group">
              <%!-- Card Header --%>
              <div class="flex flex-wrap items-center justify-between gap-2">
                <div class="flex items-center gap-2 truncate">
                  <%!-- Symbol Type Badge --%>
                  <span class={[
                    "px-2 py-0.5 rounded text-[10px] font-bold uppercase font-mono border",
                    symbol.type in [:function, :def] && symbol.visibility == :public &&
                      "bg-success/10 text-success border-success/30",
                    symbol.type in [:function, :defp] && symbol.visibility == :private &&
                      "bg-warning/10 text-warning border-warning/30",
                    symbol.type in [:module, :defmodule] &&
                      "bg-accent/10 text-accent border-accent/30",
                    symbol.type in [:macro, :defmacro, :defmacrop] &&
                      "bg-accent/10 text-accent border-accent/30",
                    symbol.type == :spec && "bg-info/10 text-info border-info/30",
                    symbol.type == :callback &&
                      "bg-accent/10 text-accent border-accent/30",
                    symbol.type == :type && "bg-accent/10 text-accent border-accent/30",
                    symbol.type in [:doc, :moduledoc] &&
                      "bg-subtle/10 text-muted border-subtle/30"
                  ]}>
                    {to_string(symbol.type)}
                  </span>

                  <%!-- Symbol Name & Module --%>
                  <span class="font-bold text-content text-xs truncate">
                    {symbol.name}{if symbol.arity, do: "/#{symbol.arity}", else: ""}
                  </span>

                  <%= if symbol.module do %>
                    <span class="text-subtle text-[11px] truncate">({symbol.module})</span>
                  <% end %>
                </div>

                <div class="flex items-center gap-2 shrink-0">
                  <span class="text-[11px] text-muted">{symbol.file}:{symbol.line}</span>
                  <button
                    type="button"
                    phx-click="jump_to_symbol"
                    phx-value-path={symbol.file}
                    phx-value-line={to_string(symbol.line)}
                    class="px-2.5 py-1 bg-raised hover:bg-accent/10 hover:text-accent hover:border-accent/40 text-muted border border-line rounded-lg text-[11px] font-semibold transition-smooth flex items-center gap-1"
                  >
                    <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
                    <span>Jump to Editor</span>
                  </button>
                </div>
              </div>

              <%!-- Code Snippet --%>
              <%= if symbol.code && symbol.code != "" do %>
                <div class="p-2.5 bg-inset border border-line rounded-lg overflow-x-auto">
                  <pre class="text-muted font-mono text-[11px] leading-relaxed whitespace-pre-wrap">{symbol.code}</pre>
                </div>
              <% end %>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Memory & Micro-GC Telemetry Footer Pill
  # ============================================================================

  @doc """
  Renders the real-time physical memory, BEAM VM allocators, process count,
  and micro-GC telemetry status pill with an interactive luxury popover card.
  """
  attr :snapshot, :any, default: nil, doc: "IexCode.Observability.MemorySnapshot struct"

  def memory_telemetry_pill(assigns) do
    alias IexCode.Observability.MemorySnapshot

    snapshot =
      case assigns.snapshot do
        %MemorySnapshot{} = s -> s
        map when is_map(map) -> MemorySnapshot.new(map)
        _ -> MemorySnapshot.new()
      end

    assigns = assign(assigns, :snapshot, snapshot)

    ~H"""
    <div
      id="memory-telemetry-pill"
      class="tooltip-trigger relative inline-flex items-center gap-2 px-2.5 py-1 rounded-md bg-surface/90 hover:bg-raised border border-line hover:border-line text-[11px] font-mono transition-smooth cursor-pointer select-none group"
    >
      <%!-- Health Status Indicator Dot --%>
      <span class={[
        "w-1.5 h-1.5 rounded-full shrink-0 transition-colors",
        memory_status_dot_class(@snapshot)
      ]} />

      <%!-- OS Physical RSS Metric --%>
      <span id="memory-rss-stat" class="text-muted group-hover:text-content flex items-center gap-1">
        <span class="text-subtle font-semibold">RSS</span>
        <span class="font-medium text-success">
          {MemorySnapshot.format_bytes(@snapshot.rss_bytes)}
        </span>
      </span>

      <span class="text-subtle font-thin">·</span>

      <%!-- BEAM Total Allocator Metric --%>
      <span id="memory-beam-stat" class="text-muted group-hover:text-content flex items-center gap-1">
        <span class="text-subtle font-semibold">BEAM</span>
        <span class="font-medium text-accent">
          {MemorySnapshot.format_bytes(@snapshot.beam_total_bytes)}
        </span>
      </span>

      <span class="text-subtle font-thin">·</span>

      <%!-- Process Count Metric --%>
      <span
        id="memory-procs-stat"
        class="text-muted group-hover:text-content flex items-center gap-1"
      >
        <span class="font-medium text-accent">{@snapshot.process_count}</span>
        <span class="text-subtle">procs</span>
      </span>

      <%!-- Micro-GC Delta Indicator (shown when reclamation occurred) --%>
      <%= if @snapshot.delta_gc_runs > 0 do %>
        <span
          id="memory-gc-delta-stat"
          class="text-[10px] px-1 py-0.5 rounded bg-warning/10 text-warning border border-warning/20"
        >
          +{@snapshot.delta_gc_runs} GC
        </span>
      <% end %>

      <%!-- Luxury Floating Popover / Tooltip --%>
      <div
        id="memory-popover-card"
        class="luxury-tooltip min-w-[340px] max-w-[400px] p-4 bg-inset/98 border border-line rounded-2xl shadow-2xl backdrop-blur-xl"
      >
        <%!-- Card Header --%>
        <div class="flex items-center justify-between pb-2.5 mb-2.5 border-b border-line">
          <div class="flex items-center gap-2">
            <.icon name="hero-cpu-chip" class="w-4 h-4 text-accent" />
            <span class="text-xs font-semibold text-content tracking-tight">BEAM & OS Memory Telemetry</span>
          </div>
          <span class="text-[10px] font-mono text-muted bg-raised px-2 py-0.5 rounded border border-line">
            OTP {:erlang.system_info(:otp_release)}
          </span>
        </div>

        <%!-- Memory Breakdown Grid --%>
        <div class="space-y-1.5 font-mono text-[11px] mb-3">
          <div class="text-[10px] uppercase tracking-wider text-subtle font-semibold mb-1">
            Memory Allocator Breakdown
          </div>

          <div class="flex items-center justify-between text-muted py-0.5">
            <span class="text-muted flex items-center gap-1.5">
              <span class="w-1.5 h-1.5 rounded-full bg-success"></span> OS Physical RSS
            </span>
            <span class="font-semibold text-content">{MemorySnapshot.format_bytes(@snapshot.rss_bytes)}</span>
          </div>

          <div class="flex items-center justify-between text-muted py-0.5">
            <span class="text-muted flex items-center gap-1.5">
              <span class="w-1.5 h-1.5 rounded-full bg-accent"></span> BEAM Total Allocator
            </span>
            <span class="font-semibold text-content">{MemorySnapshot.format_bytes(
              @snapshot.beam_total_bytes
            )}</span>
          </div>

          <div class="flex items-center justify-between text-muted py-0.5 pl-3 border-l border-line">
            <span class="text-muted">Processes (Heap & Stack)</span>
            <span id="memory-breakdown-processes" class="text-muted">
              {MemorySnapshot.format_bytes(@snapshot.beam_processes_bytes)}
            </span>
          </div>

          <div class="flex items-center justify-between text-muted py-0.5 pl-3 border-l border-line">
            <span class="text-muted">System (Overhead & Runtime)</span>
            <span id="memory-breakdown-system" class="text-muted">
              {MemorySnapshot.format_bytes(@snapshot.beam_system_bytes)}
            </span>
          </div>

          <div class="flex items-center justify-between text-muted py-0.5 pl-3 border-l border-line">
            <span class="text-muted">Atom Table</span>
            <span id="memory-breakdown-atom" class="text-muted">
              {MemorySnapshot.format_bytes(@snapshot.beam_atom_bytes)}
            </span>
          </div>

          <div class="flex items-center justify-between text-muted py-0.5 pl-3 border-l border-line">
            <span class="text-muted">Binary (Off-Heap)</span>
            <span id="memory-breakdown-binary" class="text-muted">
              {MemorySnapshot.format_bytes(@snapshot.beam_binary_bytes)}
            </span>
          </div>

          <div class="flex items-center justify-between text-muted py-0.5 pl-3 border-l border-line">
            <span class="text-muted">ETS Tables</span>
            <span id="memory-breakdown-ets" class="text-muted">
              {MemorySnapshot.format_bytes(@snapshot.beam_ets_bytes)}
            </span>
          </div>
        </div>

        <%!-- Micro-GC Telemetry Panel --%>
        <div class="p-2.5 rounded-xl bg-raised/80 border border-line space-y-1.5 font-mono text-[11px] mb-3">
          <div class="flex items-center justify-between text-[10px] uppercase tracking-wider text-muted font-semibold">
            <span class="flex items-center gap-1.5">
              <.icon name="hero-arrow-path" class="w-3.5 h-3.5 text-warning" /> Micro-GC Telemetry
            </span>
            <%= if @snapshot.delta_gc_runs > 0 do %>
              <span class="text-warning font-normal">Active reclamation</span>
            <% else %>
              <span class="text-subtle font-normal">Idle</span>
            <% end %>
          </div>

          <div class="flex items-center justify-between text-muted pt-1 border-t border-line">
            <span class="text-muted">Total GC Runs</span>
            <span id="memory-gc-runs" class="text-muted font-medium">
              {@snapshot.gc_runs}
              <%= if @snapshot.delta_gc_runs > 0 do %>
                <span class="text-warning text-[10px] ml-1">(+{@snapshot.delta_gc_runs} tick)</span>
              <% end %>
            </span>
          </div>

          <div class="flex items-center justify-between text-muted">
            <span class="text-muted">Words Reclaimed</span>
            <span id="memory-gc-words" class="text-muted font-medium">
              {@snapshot.gc_words_reclaimed}
            </span>
          </div>

          <div class="flex items-center justify-between text-muted">
            <span class="text-muted">Bytes Reclaimed</span>
            <span id="memory-gc-reclaimed" class="text-success font-medium">
              {MemorySnapshot.format_bytes(@snapshot.gc_words_reclaimed * 8)}
              <%= if @snapshot.delta_reclaimed_bytes > 0 do %>
                <span class="text-success text-[10px] ml-1">(+{MemorySnapshot.format_bytes(
                  @snapshot.delta_reclaimed_bytes
                )})</span>
              <% end %>
            </span>
          </div>
        </div>

        <%!-- Force GC Action Button --%>
        <div class="pt-2 border-t border-line flex items-center justify-between">
          <span class="text-[10px] font-mono text-muted">
            Active Procs: <strong class="text-content">{@snapshot.process_count}</strong>
          </span>
          <button
            id="force-gc-btn"
            type="button"
            phx-click="force_gc"
            class="inline-flex items-center gap-1.5 px-3 py-1 rounded-lg bg-raised hover:bg-accent/10 border border-warning/30 text-warning hover:text-warning text-xs font-mono font-medium transition-smooth cursor-pointer"
          >
            <.icon name="hero-sparkles" class="w-3.5 h-3.5 text-warning" />
            <span>Force GC</span>
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp memory_status_dot_class(%IexCode.Observability.MemorySnapshot{rss_bytes: rss})
       when is_integer(rss) do
    cond do
      rss > 800 * 1024 * 1024 ->
        "bg-danger"

      rss > 300 * 1024 * 1024 ->
        "bg-warning"

      true ->
        "bg-success"
    end
  end

  defp memory_status_dot_class(_), do: "bg-success"
end

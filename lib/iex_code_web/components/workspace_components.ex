defmodule IexCodeWeb.WorkspaceComponents do
  @moduledoc """
  Reusable Phoenix Function Components for the Next-Level IexCode Desktop UI.
  Implements Milestone 3 UI/UX & Live Telemetry Features:
  - F5: Live Telemetry & 4-Column Subagent Cards (<.subagent_cards>)
  - F6: Hierarchical Operation Tree (<.operation_tree>, <.tree_node>)
  - F7: Interactive Code Diff Viewer (<.diff_viewer>)
  - F8: File Tree Explorer & Search (<.file_explorer>)
  - F9: Terminal Session Integration (<.terminal_session>)
  """
  use Phoenix.Component
  import IexCodeWeb.CoreComponents
  import Phoenix.HTML
  alias IexCode.Engine.OperationManager

  # ============================================================================
  # F5: Live Telemetry & 4-Column Subagent Cards
  # ============================================================================

  @doc """
  Renders a 4-column live telemetry grid for OTP subagents (Planner, Explorer, Coder, Verifier).
  Includes real-time progress bars (0-100%), execution latency in ms, PID monitors, and active state indicators.
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
        icon: "hero-map",
        color: "purple",
        bg_color: "bg-purple-500",
        text_color: "text-purple-400",
        border_color: "border-purple-500/50",
        shadow: "shadow-[0_0_10px_rgba(168,85,247,0.5)]"
      },
      %{
        name: "ExplorerAgent",
        key: :explorer,
        title: "Explorer",
        desc: "AST code discovery, file tree inspection, symbol lookups",
        icon: "hero-magnifying-glass",
        color: "cyan",
        bg_color: "bg-cyan-500",
        text_color: "text-cyan-400",
        border_color: "border-cyan-500/50",
        shadow: "shadow-[0_0_10px_rgba(6,182,212,0.5)]"
      },
      %{
        name: "CoderAgent",
        key: :coder,
        title: "Coder",
        desc: "MultiPatch fuzzy patch formulation & atomic file generation",
        icon: "hero-code-bracket",
        color: "amber",
        bg_color: "bg-amber-500",
        text_color: "text-amber-400",
        border_color: "border-amber-500/50",
        shadow: "shadow-[0_0_10px_rgba(245,158,11,0.5)]"
      },
      %{
        name: "VerifierAgent",
        key: :verifier,
        title: "Verifier",
        desc: "ExUnit test runner, compiler backtrace parser & AutoFix loop",
        icon: "hero-check-badge",
        color: "emerald",
        bg_color: "bg-emerald-500",
        text_color: "text-emerald-400",
        border_color: "border-emerald-500/50",
        shadow: "shadow-[0_0_10px_rgba(34,197,94,0.5)]"
      }
    ]

    assigns = assign(assigns, :agents, agents)

    ~H"""
    <div id="subagent-cards-grid" class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4">
      <%= for agent <- @agents do %>
        <% op = latest_op_for_agent(@operations, agent.name)

        status =
          cond do
            is_nil(op) or is_nil(op.status) -> "idle"
            is_binary(op.status) -> op.status
            is_atom(op.status) -> Atom.to_string(op.status)
            true -> to_string(op.status)
          end

        progress = if op && is_number(op.progress), do: op.progress, else: 0
        pid_str = if op && op.pid_str, do: op.pid_str, else: nil
        duration = if op && op.duration_ms, do: "#{op.duration_ms}ms", else: "--"
        current_msg = if op, do: op.result || op.title || agent.desc, else: agent.desc %>
        <div
          id={"subagent-card-#{agent.key}"}
          class={[
            "bg-[#11151c] border rounded-2xl p-4 flex flex-col justify-between transition-smooth relative overflow-hidden",
            status == "running" && "#{agent.border_color} shadow-lg shadow-#{agent.color}-500/10",
            status != "running" && "border-[#21262d] hover:border-[#30363d]"
          ]}
        >
          <!-- Active neon top line -->
          <%= if status == "running" do %>
            <div class={[
              "absolute top-0 left-0 right-0 h-0.5",
              agent.bg_color,
              agent.shadow,
              "animate-pulse"
            ]}>
            </div>
          <% end %>

          <div>
            <!-- Header -->
            <div class="flex items-center justify-between mb-2">
              <span class={[
                "font-mono text-xs font-semibold uppercase tracking-wider flex items-center gap-1.5",
                agent.text_color
              ]}>
                <.icon name={agent.icon} class="w-4 h-4" />
                {agent.name}
              </span>
              <div class="flex items-center gap-1.5">
                <%= if pid_str do %>
                  <span
                    class="text-[10px] font-mono text-emerald-400 bg-emerald-500/10 px-1.5 py-0.5 rounded border border-emerald-500/20 truncate max-w-[90px]"
                    title={pid_str}
                  >
                    {pid_str}
                  </span>
                <% else %>
                  <span class="text-[10px] font-mono text-emerald-400/80 bg-emerald-500/10 px-1.5 py-0.5 rounded border border-emerald-500/20">
                    OTP Supervised
                  </span>
                <% end %>
                <span class={[
                  "text-[10px] font-mono px-1.5 py-0.5 rounded border",
                  status == "running" &&
                    "text-amber-400 bg-amber-500/10 border-amber-500/30 animate-pulse",
                  status == "completed" && "text-emerald-400 bg-emerald-500/10 border-emerald-500/30",
                  status == "failed" && "text-rose-400 bg-rose-500/10 border-rose-500/30",
                  status == "idle" && "text-gray-400 bg-[#161b22] border-[#21262d]"
                ]}>
                  {String.upcase(status)}
                </span>
              </div>
            </div>

            <!-- Role & Activity -->
            <p class="text-[11px] text-gray-400 font-mono mb-2 line-clamp-2">
              {current_msg}
            </p>
          </div>

          <!-- Progress & Latency Footer -->
          <div class="pt-3 border-t border-[#21262d] space-y-1.5">
            <div class="flex justify-between items-center text-[11px] font-mono text-gray-400">
              <span class="text-[10px] text-gray-500">Latency:
              <strong class="text-gray-300">{duration}</strong></span>
              <span class={[
                "font-semibold",
                if(status == "completed", do: "text-emerald-400", else: "text-gray-300")
              ]}>
                {progress}%
              </span>
            </div>
            <div class="w-full bg-[#1c2128] h-1.5 rounded-full overflow-hidden">
              <div
                class={[
                  "h-full rounded-full transition-all duration-300 ease-out",
                  agent.bg_color,
                  status == "running" && agent.shadow
                ]}
                style={"width: #{max(progress, if(status == "running", do: 10, else: 0))}%"}
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
      class="bg-[#11151c] border border-[#21262d] rounded-2xl p-5 space-y-4"
    >
      <!-- Tree Header -->
      <div class="flex items-center justify-between pb-3 border-b border-[#21262d]">
        <div class="flex items-center gap-3">
          <h3 class="text-sm font-semibold text-white font-mono flex items-center gap-2">
            <.icon name="hero-list-bullet" class="w-4 h-4 text-emerald-400" /> Execution Hierarchy
            <span class="px-2 py-0.5 rounded-full bg-[#1c2128] text-xs text-gray-400 border border-[#30363d]">
              {@stats.total} ops
            </span>
          </h3>
          <div class="hidden sm:flex items-center gap-2 text-[11px] font-mono text-gray-400">
            <span class="flex items-center gap-1"><span class="w-1.5 h-1.5 rounded-full bg-emerald-400"></span> {@stats.completed} done</span>
            <span class="flex items-center gap-1"><span class="w-1.5 h-1.5 rounded-full bg-amber-400 animate-pulse"></span> {@stats.running} running</span>
            <%= if @stats.failed > 0 do %>
              <span class="flex items-center gap-1 text-rose-400"><span class="w-1.5 h-1.5 rounded-full bg-rose-400"></span> {@stats.failed} failed</span>
            <% end %>
          </div>
        </div>

        <button
          phx-click="clear_operations"
          class="text-xs font-mono text-gray-500 hover:text-rose-400 transition-smooth flex items-center gap-1"
        >
          <.icon name="hero-trash" class="w-3.5 h-3.5" /> Clear Operations
        </button>
      </div>

      <!-- Tree Nodes List -->
      <%= if @tree == [] do %>
        <div class="p-8 text-center text-gray-500 font-mono text-xs border border-dashed border-[#21262d] rounded-xl">
          No operations recorded in this session.
        </div>
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
        @op.status == "running" && "bg-[#161b22] border-amber-500/40 shadow-sm",
        @op.status == "failed" && "bg-[#1a1215] border-rose-500/40",
        @op.status != "running" && @op.status != "failed" &&
          "bg-[#161b22] border-[#21262d] hover:border-[#38404a]"
      ]}>
        <!-- Top Row: Status, Agent, Title, Metrics, Chevron -->
        <div class="flex items-center justify-between gap-2">
          <div class="flex items-center gap-2.5 min-w-0 flex-1">
            <!-- Expand / Collapse chevron if children exist -->
            <%= if @has_children do %>
              <button
                phx-click="toggle_op_detail"
                phx-value-id={@op.id}
                class="text-gray-400 hover:text-white transition-smooth"
              >
                <.icon
                  name={if(@is_expanded, do: "hero-chevron-down", else: "hero-chevron-right")}
                  class="w-3.5 h-3.5"
                />
              </button>
            <% else %>
              <span class="w-3.5"></span>
            <% end %>

            <!-- Status Dot -->
            <span class={[
              "w-2 h-2 rounded-full shrink-0",
              @op.status == "completed" && "bg-emerald-400",
              @op.status == "running" &&
                "bg-amber-400 animate-pulse shadow-[0_0_8px_rgba(245,158,11,0.6)]",
              @op.status == "failed" && "bg-rose-400 shadow-[0_0_8px_rgba(244,63,94,0.6)]",
              @op.status == "pending" && "bg-gray-500"
            ]}></span>

            <!-- Agent Tag -->
            <span class="font-bold text-white shrink-0 text-xs">
              {@op.agent_name || "System"}
            </span>

            <!-- Operation Type Badge -->
            <span class="text-[10px] text-gray-400 bg-[#0d1117] border border-[#21262d] px-1.5 py-0.5 rounded shrink-0">
              {@op.op_type}
            </span>

            <!-- Title -->
            <span class="text-gray-300 truncate text-xs">
              {@op.title}
            </span>
          </div>

          <!-- Right side metrics -->
          <div class="flex items-center gap-3 text-[11px] text-gray-400 shrink-0">
            <%= if @op.duration_ms do %>
              <span class="text-gray-400">{@op.duration_ms}ms</span>
            <% end %>
            <%= if @op.pid_str do %>
              <span class="text-emerald-400 bg-emerald-500/10 px-1.5 py-0.5 rounded border border-emerald-500/20 text-[10px]">
                {@op.pid_str}
              </span>
            <% end %>
            <button
              phx-click="toggle_op_detail"
              phx-value-id={@op.id}
              class="text-gray-400 hover:text-white p-1 rounded transition-smooth"
              title="Inspect Details"
            >
              <.icon name="hero-ellipsis-horizontal" class="w-3.5 h-3.5" />
            </button>
          </div>
        </div>

        <!-- Detail Drawer (Parameters, Error, Result) -->
        <%= if @is_expanded do %>
          <div class="mt-3 pt-3 border-t border-[#21262d] space-y-2 text-[11px] font-mono animate-in fade-in">
            <%= if @op.error_message do %>
              <div class="p-2.5 rounded-lg bg-rose-950/40 border border-rose-500/30 text-rose-300 whitespace-pre-wrap">
                <strong class="text-rose-400">Error:</strong> {@op.error_message}
              </div>
            <% end %>

            <%= if @op.result do %>
              <div class="p-2.5 rounded-lg bg-[#0d1117] border border-[#21262d] text-gray-300 whitespace-pre-wrap max-h-48 overflow-y-auto">
                <strong class="text-gray-400 block mb-1">Result:</strong>
                {@op.result}
              </div>
            <% end %>

            <%= if @op.params && @op.params != %{} do %>
              <div class="p-2 rounded bg-[#0d1117] border border-[#21262d] text-gray-400">
                <span class="text-gray-500">Params:</span> {inspect(@op.params)}
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <!-- Recursive Children Rendering -->
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
  # F7: Interactive Code Diff Viewer
  # ============================================================================

  @doc """
  Renders side-by-side and inline syntax-highlighted code diff viewer for proposed and applied multi-file patches.
  Consumes unified diff strings from MultiPatch and Git diffs.
  """
  attr :diff_text, :string, default: ""
  attr :diff_mode, :string, default: "inline"
  attr :file_path, :string, default: nil

  def diff_viewer(assigns) do
    ~H"""
    <div
      id="diff-viewer-container"
      class="bg-[#11151c] border border-[#21262d] rounded-2xl flex flex-col h-full overflow-hidden"
    >
      <!-- Toolbar Header -->
      <div class="p-3 border-b border-[#21262d] bg-[#161b22] flex items-center justify-between shrink-0 font-mono text-xs">
        <div class="flex items-center gap-2">
          <.icon name="hero-code-bracket-square" class="w-4 h-4 text-cyan-400" />
          <span class="font-semibold text-white truncate max-w-md">
            {@file_path || "Multi-File Patch Preview"}
          </span>
        </div>

        <div class="flex items-center gap-3">
          <!-- View Mode Toggle -->
          <div class="flex items-center bg-[#0d1117] p-1 rounded-lg border border-[#21262d]">
            <button
              phx-click="set_diff_mode"
              phx-value-mode="inline"
              class={[
                "px-2.5 py-1 rounded text-xs transition-smooth",
                @diff_mode == "inline" && "bg-[#21262d] text-white font-semibold",
                @diff_mode != "inline" && "text-gray-400 hover:text-gray-200"
              ]}
            >
              Inline
            </button>
            <button
              phx-click="set_diff_mode"
              phx-value-mode="split"
              class={[
                "px-2.5 py-1 rounded text-xs transition-smooth",
                @diff_mode == "split" && "bg-[#21262d] text-white font-semibold",
                @diff_mode != "split" && "text-gray-400 hover:text-gray-200"
              ]}
            >
              Side-by-Side
            </button>
          </div>

          <!-- Copy Button -->
          <button
            id="copy-diff-btn"
            phx-hook="CodeCopy"
            data-code={@diff_text}
            class="px-2.5 py-1 bg-[#21262d] hover:bg-[#30363d] text-gray-200 rounded-lg text-xs font-mono transition-smooth flex items-center gap-1.5"
          >
            <.icon name="hero-clipboard-document" class="w-3.5 h-3.5" />
            <span>Copy Diff</span>
          </button>
        </div>
      </div>

      <!-- Diff Body -->
      <div class="flex-1 overflow-auto font-mono text-xs leading-relaxed p-2 bg-[#0a0d12]">
        <%= if is_nil(@diff_text) or String.trim(@diff_text) == "" do %>
          <div class="p-8 text-center text-gray-500">
            No patch or diff selected.
          </div>
        <% else %>
          <%= if @diff_mode == "inline" do %>
            <.inline_diff diff={@diff_text} />
          <% else %>
            <.split_diff diff={@diff_text} />
          <% end %>
        <% end %>
      </div>
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
              {"bg-emerald-950/40 border-l-2 border-emerald-500", "text-emerald-300", "+"}

            String.starts_with?(line, "-") && !String.starts_with?(line, "---") ->
              {"bg-rose-950/40 border-l-2 border-rose-500", "text-rose-300", "-"}

            String.starts_with?(line, "@@") ->
              {"bg-indigo-950/30 text-indigo-300 font-semibold my-1 py-0.5 px-2 rounded",
               "text-indigo-300", "@"}

            String.starts_with?(line, "---") || String.starts_with?(line, "+++") ->
              {"bg-[#161b22] text-gray-400 font-semibold py-1 px-2", "text-gray-400", "#"}

            true ->
              {"hover:bg-[#11151c]", "text-gray-300", " "}
          end %>
        <div class={["flex items-center px-2 py-0.5 rounded font-mono", bg]}>
          <span class="w-10 text-right text-gray-600 select-none pr-3 text-[10px]">{idx}</span>
          <span class="w-4 text-center select-none font-bold text-[11px] text-gray-500">{sign}</span>
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
    <div class="grid grid-cols-2 gap-2">
      <div class="space-y-0.5 border-r border-[#21262d] pr-2">
        <div class="text-gray-500 text-[10px] uppercase font-bold px-2 py-1 bg-[#11151c] rounded mb-1">
          Original
        </div>
        <%= for {line, idx} <- Enum.with_index(@lines, 1) do %>
          <%= if !String.starts_with?(line, "+") || String.starts_with?(line, "+++") do %>
            <div class={[
              "px-2 py-0.5 rounded flex items-center",
              String.starts_with?(line, "-") &&
                "bg-rose-950/40 text-rose-300 border-l-2 border-rose-500"
            ]}>
              <span class="w-8 text-right text-gray-600 select-none pr-2 text-[10px]">{idx}</span>
              <span class="flex-1 whitespace-pre-wrap">{line}</span>
            </div>
          <% end %>
        <% end %>
      </div>
      <div class="space-y-0.5 pl-2">
        <div class="text-gray-500 text-[10px] uppercase font-bold px-2 py-1 bg-[#11151c] rounded mb-1">
          Modified
        </div>
        <%= for {line, idx} <- Enum.with_index(@lines, 1) do %>
          <%= if !String.starts_with?(line, "-") || String.starts_with?(line, "---") do %>
            <div class={[
              "px-2 py-0.5 rounded flex items-center",
              String.starts_with?(line, "+") &&
                "bg-emerald-950/40 text-emerald-300 border-l-2 border-emerald-500"
            ]}>
              <span class="w-8 text-right text-gray-600 select-none pr-2 text-[10px]">{idx}</span>
              <span class="flex-1 whitespace-pre-wrap">{line}</span>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # ============================================================================
  # F8: File Tree Explorer & Search
  # ============================================================================

  @doc """
  Renders a collapsible file directory tree with instant search filtering, file selection, and syntax preview.
  """
  attr :files, :list, default: []
  attr :filter, :string, default: ""
  attr :selected_file, :string, default: nil
  attr :file_content, :string, default: nil

  def file_explorer(assigns) do
    filtered_files =
      if assigns.filter == "" or is_nil(assigns.filter) do
        assigns.files
      else
        query = String.downcase(assigns.filter)
        Enum.filter(assigns.files, &String.contains?(String.downcase(&1), query))
      end

    assigns = assign(assigns, filtered_files: filtered_files)

    ~H"""
    <div id="file-explorer-container" class="flex-1 flex h-full overflow-hidden bg-[#0a0d12]">
      <!-- Left Tree / List Navigation -->
      <div class="w-80 border-r border-[#21262d] bg-[#11151c] flex flex-col h-full overflow-hidden shrink-0">
        <!-- Search Header -->
        <div class="p-3 border-b border-[#21262d]">
          <div class="relative">
            <input
              type="text"
              name="filter"
              value={@filter}
              placeholder="Search files (e.g. .ex)..."
              phx-change="filter_files"
              class="w-full bg-[#0d1117] border border-[#30363d] rounded-xl px-3 py-1.5 pl-8 text-xs text-white placeholder-gray-500 font-mono focus:border-cyan-500 focus:outline-none"
            />
            <.icon name="hero-magnifying-glass" class="w-4 h-4 text-gray-400 absolute left-2.5 top-2" />
          </div>
          <div class="flex items-center justify-between mt-2 px-1 text-[11px] font-mono text-gray-400">
            <span>{length(@filtered_files)} files</span>
            <button
              phx-click="refresh_files"
              class="hover:text-white transition-smooth flex items-center gap-1"
            >
              <.icon name="hero-arrow-path" class="w-3 h-3" /> Refresh
            </button>
          </div>
        </div>

        <!-- Files List -->
        <div class="flex-1 overflow-y-auto p-2 space-y-0.5 font-mono text-xs">
          <%= for file <- @filtered_files do %>
            <button
              phx-click="select_file"
              phx-value-path={file}
              class={[
                "w-full text-left px-2.5 py-1.5 rounded-lg truncate transition-smooth flex items-center gap-2",
                @selected_file == file &&
                  "bg-[#21262d] text-cyan-300 font-medium shadow-sm border border-[#30363d]",
                @selected_file != file && "text-gray-400 hover:text-gray-200 hover:bg-[#161b22]"
              ]}
            >
              <.icon
                name={file_icon(file)}
                class={["w-3.5 h-3.5 shrink-0", @selected_file == file && "text-cyan-400"]}
              />
              <span class="truncate">{file}</span>
            </button>
          <% end %>
        </div>
      </div>

      <!-- Right Syntax Preview Pane -->
      <div class="flex-1 flex flex-col h-full bg-[#0a0d12] overflow-hidden">
        <%= if @selected_file do %>
          <!-- File Header -->
          <div class="p-3 border-b border-[#21262d] bg-[#11151c] flex items-center justify-between shrink-0 font-mono text-xs">
            <div class="flex items-center gap-2">
              <.icon name={file_icon(@selected_file)} class="w-4 h-4 text-cyan-400" />
              <span class="text-white font-semibold">{@selected_file}</span>
            </div>
            <button
              id="copy-file-btn"
              phx-hook="CodeCopy"
              data-code={@file_content || ""}
              class="px-2.5 py-1 bg-[#21262d] hover:bg-[#30363d] text-gray-200 rounded-lg text-xs font-mono transition-smooth flex items-center gap-1.5"
            >
              <.icon name="hero-clipboard-document" class="w-3.5 h-3.5" />
              <span>Copy</span>
            </button>
          </div>

          <!-- File Content -->
          <div class="flex-1 overflow-auto p-4 font-mono text-xs text-gray-300 leading-relaxed bg-[#0a0d12]">
            <pre phx-no-curly-interpolation><%= @file_content || "Loading file..." %></pre>
          </div>
        <% else %>
          <div class="flex-1 flex items-center justify-center text-gray-500 font-mono text-xs">
            Select a workspace file on the left to preview contents.
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp file_icon(path) do
    cond do
      String.ends_with?(path, [".ex", ".exs"]) -> "hero-cube"
      String.ends_with?(path, [".heex", ".html"]) -> "hero-code-bracket"
      String.ends_with?(path, [".css", ".scss"]) -> "hero-paint-brush"
      String.ends_with?(path, [".js", ".ts"]) -> "hero-bolt"
      String.ends_with?(path, [".json", ".yaml", ".yml"]) -> "hero-document-text"
      true -> "hero-document"
    end
  end

  # ============================================================================
  # F9: Terminal Session Integration
  # ============================================================================

  @doc """
  Renders an integrated ANSI-formatted terminal session runner with quick action buttons, shell input, and auto-scrolling.
  """
  attr :output, :string, default: ""
  attr :form, :any, required: true

  def terminal_session(assigns) do
    ~H"""
    <div
      id="terminal-session-container"
      class="flex-1 flex flex-col h-full bg-[#0a0d12] p-5 space-y-3"
    >
      <!-- Quick Action Buttons -->
      <div class="flex items-center justify-between shrink-0">
        <div class="flex items-center gap-2">
          <button
            phx-click="run_terminal"
            phx-value-command="mix test"
            class="px-2.5 py-1 bg-[#161b22] hover:bg-[#21262d] border border-[#30363d] rounded-lg text-xs font-mono text-gray-300 transition-smooth"
          >
            mix test
          </button>
          <button
            phx-click="run_terminal"
            phx-value-command="mix precommit"
            class="px-2.5 py-1 bg-[#161b22] hover:bg-[#21262d] border border-[#30363d] rounded-lg text-xs font-mono text-gray-300 transition-smooth"
          >
            mix precommit
          </button>
          <button
            phx-click="run_terminal"
            phx-value-command="git status"
            class="px-2.5 py-1 bg-[#161b22] hover:bg-[#21262d] border border-[#30363d] rounded-lg text-xs font-mono text-gray-300 transition-smooth"
          >
            git status
          </button>
          <button
            phx-click="run_terminal"
            phx-value-command="git diff"
            class="px-2.5 py-1 bg-[#161b22] hover:bg-[#21262d] border border-[#30363d] rounded-lg text-xs font-mono text-gray-300 transition-smooth"
          >
            git diff
          </button>
        </div>

        <button
          phx-click="clear_terminal"
          class="text-xs font-mono text-gray-500 hover:text-gray-300 transition-smooth"
        >
          Clear
        </button>
      </div>

      <!-- Terminal Output Display with AutoScroll Hook -->
      <div
        id="terminal-output-viewport"
        phx-hook=".TerminalAutoScroll"
        class="flex-1 bg-[#0d1117] border border-[#21262d] rounded-2xl p-4 font-mono text-xs text-gray-200 overflow-y-auto whitespace-pre-wrap leading-relaxed shadow-inner"
      >
        {ansi_to_html(@output)}
      </div>

      <!-- Terminal Command Input Form -->
      <.form
        for={@form}
        id="terminal-form"
        phx-submit="run_terminal_command"
        class="flex gap-2 shrink-0"
      >
        <div class="relative flex-1">
          <span class="absolute left-3 top-2.5 text-emerald-400 font-mono text-xs font-bold">$</span>
          <input
            type="text"
            name="command"
            placeholder="Enter shell command..."
            class="w-full bg-[#11151c] border border-[#21262d] rounded-xl pl-7 pr-4 py-2 text-xs font-mono text-white focus:outline-none focus:border-emerald-500"
          />
        </div>
        <button
          type="submit"
          class="px-4 py-2 bg-emerald-600 hover:bg-emerald-500 text-white rounded-xl text-xs font-mono font-medium transition-smooth"
        >
          Run
        </button>
      </.form>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".TerminalAutoScroll">
        export default {
          mounted() {
            this.scrollToBottom()
          },
          updated() {
            this.scrollToBottom()
          },
          scrollToBottom() {
            this.el.scrollTop = this.el.scrollHeight
          }
        }
      </script>
    </div>
    """
  end

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
    |> String.replace("\e[37m", "<span class=\"text-gray-200 font-medium\">")
    |> String.replace("\e[90m", "<span class=\"text-gray-500 font-medium\">")
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
end

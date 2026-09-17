defmodule IexCodeWeb.EditorialChrome do
  @moduledoc """
  Direction B ("Editorial Instrument") application chrome.

  Renders the editorial masthead: wordmark, pill command-palette trigger, live
  session chip, and the primary top navigation. The masthead renders only when
  the active appearance theme is `"editorial"`, so every other theme keeps its
  existing chrome byte-for-byte. Under the editorial theme the persistent
  (wide-screen) workspace sidebar is hidden by CSS while the narrow-screen
  drawer code path stays fully functional as the fallback.
  """

  use IexCodeWeb, :html

  @nav_items [
    {:workspace, "01", "Workspace"},
    {:workflows, "02", "Workflows"},
    {:research, "03", "Research"},
    {:settings, "04", "Settings"}
  ]

  attr :appearance, :map,
    default: nil,
    doc: "appearance preferences from IexCodeWeb.Appearance; masthead renders only for editorial"

  attr :current, :atom,
    required: true,
    values: [:workspace, :workflows, :research, :settings],
    doc: "active destination for aria-current"

  attr :session, :map,
    default: nil,
    doc: "optional session (or session-like map) with :id and :model_name for the live chip"

  attr :palette_event, :string,
    default: "toggle_command_palette",
    doc: "LiveView event fired by the pill button"

  attr :palette_navigate, :string,
    default: nil,
    doc: "when set, the pill renders as a link to this path instead of a button"

  def masthead(assigns) do
    session = assigns[:session]

    assigns =
      assigns
      |> assign(:paths, nav_paths(session && Map.get(session, :id)))
      |> assign(:session_short_id, session && short_id(Map.get(session, :id)))
      |> assign(:session_model, session && Map.get(session, :model_name))
      |> assign(:nav_items, @nav_items)

    ~H"""
    <%= if editorial?(@appearance) do %>
      <header id="editorial-masthead" class="ed-masthead">
        <div class="ed-masthead-inner">
          <.link navigate={@paths.workspace} class="ed-wordmark" aria-label="IexCode workspace home">
            <span aria-hidden="true">iex<span class="ed-dot">·</span>code</span>
            <small>Editorial Instrument</small>
          </.link>
          <div class="ed-palette">
            <.link
              :if={@palette_navigate}
              navigate={@palette_navigate}
              id="editorial-palette-pill"
              class="ed-pill"
              aria-label="Open workspace command palette"
            >
              <.icon name="hero-magnifying-glass" class="ed-pill-lens" />
              <span class="ed-pill-label">Type a command — workflows, sessions, settings…</span>
              <kbd>⌘K</kbd>
            </.link>
            <button
              :if={!@palette_navigate}
              type="button"
              id="editorial-palette-pill"
              class="ed-pill"
              phx-click={@palette_event}
              aria-label="Open command palette"
              aria-keyshortcuts="meta+k control+k"
            >
              <.icon name="hero-magnifying-glass" class="ed-pill-lens" />
              <span class="ed-pill-label">Type a command — workflows, sessions, settings…</span>
              <kbd>⌘K</kbd>
            </button>
          </div>
          <div class="ed-masthead-right">
            <span :if={@session_short_id} class="ed-session-chip">
              <span class="ed-live-dot" aria-hidden="true"></span>
              <span>
                session · {@session_short_id}<span :if={@session_model}> · {@session_model}</span>
              </span>
            </span>
          </div>
        </div>
        <nav id="editorial-topnav" class="ed-topnav" aria-label="Primary">
          <ul>
            <li :for={{id, numeral, label} <- @nav_items}>
              <.link
                navigate={Map.fetch!(@paths, id)}
                id={"editorial-nav-#{id}"}
                aria-current={@current == id && "page"}
                class={["ed-topnav-link", @current == id && "is-active"]}
              >
                <span class="ed-topnav-numeral" aria-hidden="true">{numeral}</span>
                <span>{label}</span>
              </.link>
            </li>
          </ul>
        </nav>
      </header>
    <% end %>
    """
  end

  @doc """
  Returns true when the given appearance enables the editorial theme.

  Templates use this to gate editorial-only flourishes (heroes, chapter hints)
  so every other theme keeps its existing markup byte-for-byte.
  """
  def editorial?(%{ui_theme: "editorial"}), do: true
  def editorial?(_appearance), do: false

  @doc """
  Short mono hint for a settings studio chapter, shown in the editorial index.
  """
  def chapter_hint("providers"), do: "cards · live ping"
  def chapter_hint("reasoning"), do: "effort · budgets · overrides"
  def chapter_hint("safety"), do: "tiers · categories"
  def chapter_hint("context"), do: "compaction · voices"
  def chapter_hint("environment"), do: "sandbox · secrets"
  def chapter_hint("appearance"), do: "chimes · accent · density"
  def chapter_hint(_tab_id), do: ""

  attr :appearance, :map,
    default: nil,
    doc: "appearance preferences; hero renders only for the editorial theme"

  attr :id, :string, required: true, doc: "dom id for the hero section"
  attr :kicker, :string, required: true, doc: "mono eyebrow above the display title"
  attr :standfirst, :string, required: true, doc: "lede paragraph beside the title"

  attr :stats, :list,
    default: [],
    doc: "list of {value, label} display-numeral stats rendered under the title"

  attr :marginalia, :string,
    default: nil,
    doc: "optional vertical marginalia (decorative, hidden from assistive tech)"

  slot :inner_block, required: true, doc: "display title; may contain <em> for the copper voice"

  @doc """
  Direction B display hero: kicker, oversized Clash Display title, standfirst,
  and display-numeral stats on a 12-column grid. Renders only under the
  editorial theme; all placement is in-flow so LiveView-morphed heights reflow
  instead of overlapping.
  """
  def hero(assigns) do
    ~H"""
    <%= if editorial?(@appearance) do %>
      <section id={@id} class="ed-hero" aria-labelledby={"#{@id}-title"}>
        <p class="ed-hero-kicker">{@kicker}</p>
        <h1 id={"#{@id}-title"} class="ed-hero-title">{render_slot(@inner_block)}</h1>
        <p :if={@marginalia} class="ed-marginalia" aria-hidden="true">{@marginalia}</p>
        <div :if={@stats != []} class="ed-hero-meta">
          <div :for={{value, label} <- @stats}>
            <b>{value}</b>
            <span>{label}</span>
          </div>
        </div>
        <p class="ed-hero-standfirst">{@standfirst}</p>
      </section>
    <% end %>
    """
  end

  attr :appearance, :map,
    default: nil,
    doc: "appearance preferences; note renders only for the editorial theme"

  attr :id, :string, required: true, doc: "dom id for the marginal note"
  attr :body, :string, required: true, doc: "supporting paragraph under the pullquote"
  attr :byline, :string, required: true, doc: "mono byline closing the note"

  slot :inner_block, required: true, doc: "pullquote; may contain <em> for the copper voice"

  @doc """
  Direction B dark marginal note: the contrast plate. Static copy only, so it
  can tilt and stagger freely without disturbing dynamic LiveView lists.
  """
  def note(assigns) do
    ~H"""
    <%= if editorial?(@appearance) do %>
      <aside id={@id} class="ed-plate ed-plate--dark">
        <p class="ed-plate-eyebrow">Marginal note</p>
        <p class="ed-pullquote">{render_slot(@inner_block)}</p>
        <p class="ed-note-body">{@body}</p>
        <p class="ed-byline">{@byline}</p>
      </aside>
    <% end %>
    """
  end

  attr :appearance, :map,
    default: nil,
    doc: "appearance preferences; skeleton renders only for the editorial theme"

  attr :id, :string, required: true, doc: "dom id for the skeleton region"

  attr :variant, :atom,
    default: :workflow_grid,
    values: [:workflow_grid, :run_rows, :steps, :index, :kanban],
    doc: "layout shape the skeleton mirrors"

  attr :count, :integer, default: 3, doc: "how many skeleton items to render"

  @doc """
  Direction B skeleton loader: shimmer blocks that mirror the layout shape of
  the content they stand in for (workflow cards, run rows, DAG steps, settings
  index rows, kanban cards). Renders only under the editorial theme; motion is
  transform/opacity-only and collapses under `prefers-reduced-motion`.
  """
  def skeleton(assigns) do
    ~H"""
    <%= if editorial?(@appearance) do %>
      <div
        id={@id}
        class="ed-skeleton-host"
        data-ed-skeleton={@variant}
        role="status"
        aria-busy="true"
      >
        <span class="sr-only">Loading…</span>
        <.skeleton_item :for={_i <- 1..@count} variant={@variant} />
      </div>
    <% end %>
    """
  end

  attr :variant, :atom, required: true

  defp skeleton_item(%{variant: :workflow_grid} = assigns) do
    ~H"""
    <div class="ed-skeleton ed-skeleton-card" aria-hidden="true">
      <span class="ed-skeleton-bar ed-skeleton-title"></span>
      <span class="ed-skeleton-bar ed-skeleton-line"></span>
      <span class="ed-skeleton-bar ed-skeleton-line ed-skeleton-line--short"></span>
      <span class="ed-skeleton-pills">
        <i></i><i></i><i></i>
      </span>
      <span class="ed-skeleton-foot">
        <i></i><b></b>
      </span>
    </div>
    """
  end

  defp skeleton_item(%{variant: :run_rows} = assigns) do
    ~H"""
    <div class="ed-skeleton ed-skeleton-row" aria-hidden="true">
      <span class="ed-skeleton-bar ed-skeleton-chip"></span>
      <span class="ed-skeleton-bar ed-skeleton-line ed-skeleton-line--grow"></span>
      <span class="ed-skeleton-bar ed-skeleton-pill"></span>
      <span class="ed-skeleton-bar ed-skeleton-meter"></span>
    </div>
    """
  end

  defp skeleton_item(%{variant: :steps} = assigns) do
    ~H"""
    <div class="ed-skeleton ed-skeleton-step" aria-hidden="true">
      <span class="ed-skeleton-orb"></span>
      <span class="ed-skeleton-step-copy">
        <span class="ed-skeleton-bar ed-skeleton-line"></span>
        <span class="ed-skeleton-bar ed-skeleton-line ed-skeleton-line--short"></span>
      </span>
      <span class="ed-skeleton-bar ed-skeleton-tag"></span>
    </div>
    """
  end

  defp skeleton_item(%{variant: :index} = assigns) do
    ~H"""
    <div class="ed-skeleton ed-skeleton-index" aria-hidden="true">
      <span class="ed-skeleton-bar ed-skeleton-numeral"></span>
      <span class="ed-skeleton-step-copy">
        <span class="ed-skeleton-bar ed-skeleton-chapter"></span>
        <span class="ed-skeleton-bar ed-skeleton-hint"></span>
      </span>
    </div>
    """
  end

  defp skeleton_item(%{variant: :kanban} = assigns) do
    ~H"""
    <div class="ed-skeleton ed-skeleton-kanban" aria-hidden="true">
      <span class="ed-skeleton-kanban-meta">
        <i></i><b></b>
      </span>
      <span class="ed-skeleton-bar ed-skeleton-line"></span>
      <span class="ed-skeleton-bar ed-skeleton-line ed-skeleton-line--short"></span>
    </div>
    """
  end

  attr :appearance, :map,
    default: nil,
    doc: "appearance preferences; empty state renders only for the editorial theme"

  attr :id, :string, required: true, doc: "dom id for the empty state"
  attr :eyebrow, :string, required: true, doc: "mono eyebrow above the title"
  attr :title, :string, required: true, doc: "display title"
  attr :body, :string, required: true, doc: "supporting paragraph"

  slot :actions, doc: "copper CTA row (links or buttons)"

  @doc """
  Direction B composed empty state: eyebrow, display title, lede, and a copper
  action row on a paper plate. Static copy only, so callers keep their existing
  dom ids and LiveView events on the actions they pass in.
  """
  def empty_state(assigns) do
    ~H"""
    <%= if editorial?(@appearance) do %>
      <div id={@id} class="ed-plate ed-empty" role="status">
        <p class="ed-plate-eyebrow ed-empty-eyebrow"><i></i>{@eyebrow}</p>
        <h3 class="ed-empty-title">{@title}</h3>
        <p class="ed-empty-body">{@body}</p>
        <div :if={@actions != []} class="ed-empty-actions">
          {render_slot(@actions)}
        </div>
      </div>
    <% end %>
    """
  end

  defp nav_paths(nil) do
    %{workspace: "/", workflows: "/workflows", research: "/research", settings: "/settings"}
  end

  defp nav_paths(session_id) do
    base = "/sessions/#{session_id}"

    %{
      workspace: base,
      workflows: "#{base}/workflows",
      research: "#{base}/research",
      settings: "#{base}/settings"
    }
  end

  defp short_id(nil), do: nil
  defp short_id(id), do: id |> to_string() |> String.slice(0, 4)
end

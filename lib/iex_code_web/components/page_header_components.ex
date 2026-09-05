defmodule IexCodeWeb.PageHeaderComponents do
  @moduledoc """
  Shared page headings and compact workspace toolbars.

  Use `page_header/1` for a page title with optional description and tabs, and
  `page_toolbar/1` for workspaces whose navigation or controls lead the page.
  Action buttons and links can use the scoped `header-control` class, with
  `header-control--primary` or `header-control--icon` modifiers as needed.
  """

  use Phoenix.Component

  import IexCodeWeb.CoreComponents, only: [icon: 1]

  @doc """
  Renders the standard page heading.

  The optional `count` appears next to the title. The `tabs` slot places page
  navigation below the heading, while `actions` stays alongside it on wide
  screens. Add `page-header--panel` when the heading is a standalone panel.
  Add `page-header--flush` when the containing pane already provides horizontal
  padding, or `page-header--embedded` when it also provides top padding.
  Use `meta` for a status badge alongside the title.

  ## Example

      <.page_header id="projects-header" title="Projects" count={@project_count}>
        <:actions>
          <button id="new-project" class="header-control header-control--primary">
            New project
          </button>
        </:actions>
      </.page_header>
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :title_id, :string, default: nil
  attr :heading_tag, :string, default: "h2", values: ~w(h1 h2 h3)
  attr :description, :string, default: nil
  attr :count, :any, default: nil
  attr :icon, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  slot :actions
  slot :tabs
  slot :meta

  def page_header(assigns) do
    ~H"""
    <header id={@id} class={["page-header", @class]} {@rest}>
      <div class="page-header__row">
        <div class="page-header__identity">
          <span :if={@icon} class="page-header__icon" aria-hidden="true">
            <.icon name={@icon} class="size-[18px]" />
          </span>
          <div class="page-header__copy">
            <div class="page-header__title-row">
              <.dynamic_tag
                tag_name={@heading_tag}
                id={@title_id || "#{@id}-title"}
                class="page-header__title"
              >
                {@title}
              </.dynamic_tag>
              <span :if={not is_nil(@count)} class="page-header__count">{@count}</span>
              <div :if={@meta != []} class="page-header__meta">{render_slot(@meta)}</div>
            </div>
            <p :if={@description} class="page-header__description">{@description}</p>
          </div>
        </div>
        <div :if={@actions != []} class="page-header__actions">
          {render_slot(@actions)}
        </div>
      </div>
      <div :if={@tabs != []} class="page-header__tabs">
        {render_slot(@tabs)}
      </div>
    </header>
    """
  end

  @doc """
  Renders a compact workspace toolbar.

  The optional `leading` slot appears before the title. Use the default slot
  for context controls, and `actions` for controls aligned to the other edge.
  Add `page-toolbar--panel` when the toolbar is a standalone panel.
  Add `page-toolbar--flush` when its parent already supplies horizontal padding.
  """
  attr :id, :string, required: true
  attr :title, :string, default: nil
  attr :title_id, :string, default: nil
  attr :heading_tag, :string, default: "h2", values: ~w(h1 h2 h3)
  attr :class, :any, default: nil
  attr :rest, :global

  slot :leading
  slot :inner_block
  slot :actions

  def page_toolbar(assigns) do
    ~H"""
    <header id={@id} class={["page-toolbar", @class]} {@rest}>
      <div class="page-toolbar__main">
        <div :if={@leading != []} class="page-toolbar__leading">
          {render_slot(@leading)}
        </div>
        <.dynamic_tag
          :if={@title}
          tag_name={@heading_tag}
          id={@title_id || "#{@id}-title"}
          class="page-toolbar__title"
        >
          {@title}
        </.dynamic_tag>
        <div :if={@inner_block != []} class="page-toolbar__controls">
          {render_slot(@inner_block)}
        </div>
      </div>
      <div :if={@actions != []} class="page-toolbar__actions">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end
end

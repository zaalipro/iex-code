defmodule IexCodeWeb.Layouts do
  @moduledoc """
  Layouts for IexCode Desktop Coding Harness.
  """
  use IexCodeWeb, :html

  embed_templates "layouts/*"

  @doc """
  Renders the desktop application layout.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_scope, :map, default: nil, doc: "the current scope"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen w-full bg-[#0d1117] text-[#f0f6fc] font-sans antialiased overflow-hidden flex flex-col">
      {render_slot(@inner_block)}
      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Shows flash messages.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite" class="fixed bottom-4 right-4 z-50 flex flex-col gap-2 max-w-sm">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end

  @doc """
  Renders the real-time memory and micro-GC telemetry status pill.
  """
  defdelegate memory_telemetry_pill(assigns), to: IexCodeWeb.WorkspaceComponents
end

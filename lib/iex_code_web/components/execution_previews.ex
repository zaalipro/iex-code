defmodule IexCodeWeb.ExecutionPreviews do
  use IexCodeWeb, :html

  attr :previews, :list, required: true
  attr :id, :string, default: "execution"

  def execution_previews(assigns) do
    ~H"""
    <section
      :if={@previews != []}
      id={"#{@id}-previews"}
      aria-label="Transient model output"
      class="space-y-3"
    >
      <article
        :for={{preview, index} <- Enum.with_index(@previews)}
        id={"#{@id}-preview-#{index}"}
        data-terminal={to_string(preview.closed?)}
        data-stream-role={preview.identity.role}
        class="max-w-3xl rounded-xl border border-dashed border-line bg-surface p-4"
      >
        <div class="mb-2 flex flex-wrap items-center gap-2 font-mono text-[10px] uppercase tracking-wider text-muted">
          <.icon name="hero-signal" class="h-3.5 w-3.5" />
          <span>{preview.identity.role} · Turn {preview.identity.turn}</span>
          <span>Transient · Not saved</span>
          <span
            :if={present_value?(preview_field(preview, :tool_name, "tool_name"))}
            id={"#{@id}-preview-tool-#{index}"}
            data-preview-pill="tool-name"
            class="rounded border border-sky-500/30 bg-sky-500/10 px-1.5 py-0.5 text-sky-300"
          >
            Tool · {preview_field(preview, :tool_name, "tool_name")}
          </span>
          <span
            :if={present_value?(preview_field(preview, :iteration, "iteration"))}
            id={"#{@id}-preview-iteration-#{index}"}
            data-preview-pill="iteration"
            class="rounded border border-purple-500/30 bg-purple-500/10 px-1.5 py-0.5 text-purple-300"
          >
            Iter {preview_field(preview, :iteration, "iteration")}
          </span>
          <span
            :if={repair_mode_active?(preview_field(preview, :repair_mode, "repair_mode"))}
            id={"#{@id}-preview-repair-#{index}"}
            data-preview-pill="repair-mode"
            class="rounded border border-amber-500/30 bg-amber-500/10 px-1.5 py-0.5 text-amber-300"
          >
            {format_repair_mode(preview_field(preview, :repair_mode, "repair_mode"))}
          </span>
          <span :if={preview.partial?}>Partial continuation</span>
          <span :if={preview.truncated?}>Truncated preview</span>
          <span>{label(preview.status, preview.closed?)}</span>
        </div>
        <pre
          id={"#{@id}-preview-text-#{index}"}
          class="max-h-64 overflow-auto whitespace-pre-wrap break-words font-sans text-xs leading-relaxed text-gray-300"
        >{preview.text}</pre>
      </article>
    </section>
    """
  end

  defp preview_field(preview, atom_key, str_key) when is_map(preview) do
    case Map.get(preview, atom_key) do
      nil -> Map.get(preview, str_key)
      val -> val
    end
  end

  defp preview_field(_preview, _atom_key, _str_key), do: nil

  defp present_value?(nil), do: false
  defp present_value?(false), do: false
  defp present_value?(""), do: false
  defp present_value?(val), do: String.trim(to_string(val)) != ""

  defp repair_mode_active?(nil), do: false
  defp repair_mode_active?(false), do: false
  defp repair_mode_active?(""), do: false
  defp repair_mode_active?(true), do: true
  defp repair_mode_active?(val), do: String.trim(to_string(val)) != ""

  defp format_repair_mode(true), do: "Repair mode"
  defp format_repair_mode(mode), do: "Repair · #{mode}"

  defp label(status, true), do: "Partial · #{String.capitalize(status)}"
  defp label(status, false) when status in ~w(complete settled), do: "Awaiting saved result"
  defp label("reset", false), do: "Retrying"
  defp label(_, false), do: "Streaming"
end

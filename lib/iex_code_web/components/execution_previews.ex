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

  defp label(status, true), do: "Partial · #{String.capitalize(status)}"
  defp label(status, false) when status in ~w(complete settled), do: "Awaiting saved result"
  defp label("reset", false), do: "Retrying"
  defp label(_, false), do: "Streaming"
end

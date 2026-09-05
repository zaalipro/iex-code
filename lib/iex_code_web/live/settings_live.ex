defmodule IexCodeWeb.SettingsLive do
  @moduledoc """
  Global application defaults, credentials, and operational preferences.

  The page intentionally keeps global defaults separate from session-specific
  state. A session route supplies context and a return destination only; saving
  still updates the singleton application settings record.
  """
  use IexCodeWeb, :live_view

  alias Ecto.Changeset
  alias IexCode.{Sessions, Settings}
  alias IexCode.Research.Registry, as: SearchRegistry
  alias IexCode.LLM.Discovery

  @studio_tabs [
    {"providers", "Providers & models", "hero-cpu-chip"},
    {"reasoning", "Reasoning", "hero-sparkles"},
    {"safety", "Execution & safety", "hero-shield-check"},
    {"context", "Context & research", "hero-document-text"},
    {"environment", "Environment", "hero-variable"},
    {"appearance", "Appearance & sound", "hero-swatch"}
  ]

  @valid_tabs ~w(providers reasoning safety context environment appearance)

  @appearance_themes [
    %{
      id: "midnight",
      name: "Midnight",
      description: "Deep space surfaces illuminated by ice cyan.",
      mood: "Deep space · ice cyan"
    },
    %{
      id: "graphite",
      name: "Graphite",
      description: "Carbon surfaces with the warmth of amber bronze.",
      mood: "Carbon · amber bronze"
    },
    %{
      id: "aurora",
      name: "Aurora",
      description: "Dark forest layers with a clear mint glow.",
      mood: "Deep forest · mint"
    },
    %{
      id: "porcelain",
      name: "Porcelain",
      description: "Cool white surfaces with precise blue ink.",
      mood: "Cool white · blue ink"
    },
    %{
      id: "sandstone",
      name: "Sandstone",
      description: "Warm paper grounded by terracotta.",
      mood: "Warm paper · terracotta"
    }
  ]

  @appearance_theme_ids Enum.map(@appearance_themes, & &1.id)

  @settings_sections [
    {"models", "Model defaults"},
    {"provider-diagnostics", "Connection tests"},
    {"providers", "Search providers"},
    {"runtime", "Runtime status"},
    {"reasoning-profiles", "Thinking defaults"},
    {"model-overrides-card", "Model overrides"},
    {"payload-inspector-card", "Payload inspector"},
    {"safety-policy-card", "Approvals & sandbox"},
    {"execution", "Run defaults"},
    {"goals", "Goals"},
    {"swarm", "Swarm"},
    {"context-compaction-card", "Context window"},
    {"workspace-persona-card", "Instructions"},
    {"research", "Research"},
    {"environment-vars-card", "Variables & secrets"},
    {"visual-appearance-card", "Theme & depth"},
    {"audio-ergonomics-card", "Sound"},
    {"editor", "Editor"},
    {"usage", "Usage"}
  ]

  @section_tabs %{
    "models" => "providers",
    "provider-diagnostics" => "providers",
    "providers" => "providers",
    "runtime" => "providers",
    "reasoning-profiles" => "reasoning",
    "model-overrides-card" => "reasoning",
    "payload-inspector-card" => "reasoning",
    "safety-policy-card" => "safety",
    "execution" => "safety",
    "goals" => "safety",
    "swarm" => "safety",
    "context-compaction-card" => "context",
    "workspace-persona-card" => "context",
    "research" => "context",
    "environment-vars-card" => "environment",
    "visual-appearance-card" => "appearance",
    "audio-ergonomics-card" => "appearance",
    "editor" => "appearance",
    "usage" => "appearance"
  }

  @impl true
  def mount(params, _session, socket) do
    settings = Settings.get_settings()
    context_session = load_context_session(params["id"])
    invalid_session_context? = is_binary(params["id"]) and is_nil(context_session)

    if connected?(socket) do
      if function_exported?(Settings, :subscribe, 0), do: apply(Settings, :subscribe, [])
      Phoenix.PubSub.subscribe(IexCode.PubSub, "llm:discovery")
    end

    local_servers_status =
      if Code.ensure_loaded?(IexCode.LLM.Discovery.Server) and
           Process.whereis(IexCode.LLM.Discovery.Server) do
        IexCode.LLM.Discovery.Server.get_status()
      else
        []
      end

    {usage_status, usage_rows, usage_totals, usage_message} = load_usage(context_session)

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:active_tab, :providers)
     |> assign(:studio_tabs, @studio_tabs)
     |> assign(:provider_latencies, %{})
     |> assign(:provider_statuses, %{})
     |> assign(:preview_provider, settings.default_model_provider || "openai")
     |> assign(:preview_model, settings.default_model || "o3-mini")
     |> assign(:preview_reasoning_effort, settings.default_reasoning_effort || "medium")
     |> assign(:preview_thinking_budget, settings.default_thinking_budget || 4096)
     |> assign(:settings, settings)
     |> assign(:settings_form, settings_form(settings))
     |> assign(:settings_status, :idle)
     |> assign(:settings_message, "All changes are saved locally on this machine.")
     |> assign(:saved_at, nil)
     |> assign(:external_update?, false)
     |> assign(:context_session, context_session)
     |> assign(:invalid_session_context?, invalid_session_context?)
     |> assign(:return_path, return_path(context_session))
     |> assign(:search_provider_descriptors, ordered_descriptors(settings))
     |> assign(:provider_filter, "")
     |> assign(:expanded_providers, MapSet.new())
     |> assign(:local_servers_status, local_servers_status)
     |> assign(:scanning_local_models?, false)
     |> assign(:usage_status, usage_status)
     |> assign(:usage_rows, usage_rows)
     |> assign(:usage_totals, usage_totals)
     |> assign(:usage_message, usage_message)
     |> assign(:runtime_facts, runtime_facts())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab =
      case params["tab"] do
        t when t in @valid_tabs -> String.to_atom(t)
        _ -> :providers
      end

    context_session = load_context_session(params["id"])
    invalid_session_context? = is_binary(params["id"]) and is_nil(context_session)

    {:noreply,
     socket
     |> assign(:active_tab, tab)
     |> assign(:context_session, context_session)
     |> assign(:invalid_session_context?, invalid_session_context?)
     |> assign(:return_path, return_path(context_session))
     |> assign(:page_title, "Settings · " <> tab_title(tab))}
  end

  @impl true
  def handle_event("validate_settings", %{"settings" => params}, socket) do
    changeset = draft_changeset(socket.assigns.settings, params)

    {:noreply,
     socket
     |> assign(:settings_form, to_form(changeset, as: :settings))
     |> assign(:settings_status, :dirty)
     |> assign(:settings_message, "Unsaved changes")}
  end

  @impl true
  def handle_event("save_settings", %{"settings" => params}, socket) do
    case update_from_form(socket.assigns.settings, params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign_saved(updated, "Settings saved")
         |> put_flash(:info, "Settings saved")}

      {:error, %Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:settings_form, to_form(%{changeset | action: :validate}, as: :settings))
         |> assign(:settings_status, :error)
         |> assign(:settings_message, "Review the highlighted fields and try again.")}

      {:error, {:db_error, reason}} ->
        {:noreply, assign_save_error(socket, database_error(reason), params)}

      {:error, :stale_settings} ->
        {:noreply,
         socket
         |> assign_save_error(
           "Settings changed in another window. Discard to load the saved version, then apply your edit again.",
           params
         )
         |> assign(:external_update?, true)}

      {:error, reason} ->
        {:noreply, assign_save_error(socket, save_error(reason), params)}
    end
  end

  @impl true
  def handle_event("discard_settings", _params, socket) do
    settings = Settings.get_settings()

    {:noreply,
     socket
     |> assign(:settings, settings)
     |> assign(:settings_form, settings_form(settings))
     |> assign(:search_provider_descriptors, ordered_descriptors(settings))
     |> assign(:settings_status, :idle)
     |> assign(:settings_message, "Changes discarded. Showing saved settings.")
     |> assign(:saved_at, nil)
     |> assign(:external_update?, false)
     |> push_event("settings_clear_secrets", %{})}
  end

  @impl true
  def handle_event("clear_credential", %{"credential" => credential}, socket) do
    draft_params = form_params(socket.assigns.settings_form)

    with {:ok, credential_key} <- credential_key(credential),
         true <- function_exported?(Settings, :clear_credential, 2),
         {:ok, updated} <-
           apply(Settings, :clear_credential, [socket.assigns.settings, credential_key]) do
      {:noreply,
       socket
       |> assign_cleared_credential(updated, draft_params, credential_key)
       |> put_flash(:info, "Credential removed")}
    else
      false ->
        {:noreply,
         socket
         |> assign(:settings_status, :error)
         |> assign(:settings_message, "Credential removal is unavailable in this build.")}

      {:error, :stale_settings} ->
        {:noreply,
         socket
         |> assign_save_error(
           "Settings changed in another window. Discard to load the saved version before removing this credential.",
           draft_params
         )
         |> assign(:external_update?, true)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:settings_status, :error)
         |> assign(:settings_message, save_error(reason))}
    end
  end

  @impl true
  def handle_event("toggle_provider_advanced", %{"provider" => provider}, socket) do
    known? = Enum.any?(socket.assigns.search_provider_descriptors, &(provider_id(&1) == provider))

    expanded =
      if known? do
        toggle_set_member(socket.assigns.expanded_providers, provider)
      else
        socket.assigns.expanded_providers
      end

    {:noreply, assign(socket, :expanded_providers, expanded)}
  end

  @impl true
  def handle_event("filter_providers", params, socket) when is_map(params) do
    value = Map.get(params, "value", Map.get(params, "provider_filter", ""))
    {:noreply, assign(socket, :provider_filter, value |> to_string() |> String.slice(0, 80))}
  end

  @impl true
  def handle_event("move_provider", %{"provider" => provider, "direction" => direction}, socket)
      when direction in ["up", "down"] do
    order = provider_order(socket.assigns.settings_form, socket.assigns.settings)

    if provider in order do
      new_order = move_in_order(order, provider, direction)

      draft_params =
        socket.assigns.settings_form
        |> form_params()
        |> Map.put("search_provider_order", new_order)

      {:noreply, assign_reordered_draft(socket, draft_params, new_order)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("move_provider", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("rescan_local_models", _params, socket) do
    if Code.ensure_loaded?(IexCode.LLM.Discovery.Server) and
         Process.whereis(IexCode.LLM.Discovery.Server) do
      IexCode.LLM.Discovery.Server.rescan()
    end

    status =
      if Code.ensure_loaded?(IexCode.LLM.Discovery.Server) and
           Process.whereis(IexCode.LLM.Discovery.Server) do
        IexCode.LLM.Discovery.Server.get_status()
      else
        socket.assigns.local_servers_status
      end

    {:noreply,
     socket
     |> assign(:local_servers_status, status)
     |> assign(:scanning_local_models?, false)
     |> put_flash(:info, "Scanned local inference servers")}
  end

  @impl true
  def handle_event("use_local_model", %{"provider" => provider, "model" => model}, socket) do
    params = %{
      "default_model_provider" => provider,
      "default_model" => model
    }

    case update_from_form(socket.assigns.settings, params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign_saved(updated, "Default model set to #{model} (#{provider})")
         |> put_flash(:info, "Default model set to #{model} (#{provider})")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to set default model")}
    end
  end

  @impl true
  def handle_event("ping_provider", %{"provider" => provider}, socket) do
    settings = socket.assigns.settings

    case Discovery.ping(provider, settings) do
      {:ok, %{latency_ms: ms, model_count: count, status: :online}} ->
        status = if ms > 1000, do: :degraded, else: :online

        latencies =
          Map.put(socket.assigns.provider_latencies, provider, %{
            latency_ms: ms,
            model_count: count,
            status: status
          })

        statuses = Map.put(socket.assigns.provider_statuses, provider, status)

        {:noreply,
         socket
         |> assign(:provider_latencies, latencies)
         |> assign(:provider_statuses, statuses)
         |> put_flash(
           :info,
           "#{String.capitalize(to_string(provider))} online · #{ms}ms latency (#{count} models)"
         )}

      {:error, reason} ->
        latencies =
          Map.put(socket.assigns.provider_latencies, provider, %{
            latency_ms: nil,
            model_count: 0,
            status: :offline,
            error: inspect(reason)
          })

        statuses = Map.put(socket.assigns.provider_statuses, provider, :offline)

        {:noreply,
         socket
         |> assign(:provider_latencies, latencies)
         |> assign(:provider_statuses, statuses)
         |> put_flash(
           :error,
           "#{String.capitalize(to_string(provider))} unreachable: #{inspect(reason)}"
         )}
    end
  end

  @impl true
  def handle_event("update_preview_model", params, socket) do
    provider = params["provider"] || socket.assigns.preview_provider
    model = params["model"] || socket.assigns.preview_model
    effort = params["reasoning_effort"] || socket.assigns.preview_reasoning_effort

    budget =
      case params["thinking_budget"] do
        nil ->
          socket.assigns.preview_thinking_budget

        b when is_binary(b) ->
          case Integer.parse(b) do
            {int, ""} -> int
            _ -> socket.assigns.preview_thinking_budget
          end

        b when is_integer(b) ->
          b
      end

    {:noreply,
     socket
     |> assign(:preview_provider, provider)
     |> assign(:preview_model, model)
     |> assign(:preview_reasoning_effort, effort)
     |> assign(:preview_thinking_budget, budget)}
  end

  @impl true
  def handle_event("test_chime", %{"chime" => chime}, socket) do
    vol = socket.assigns.settings.sound_volume || 80
    IexCode.Desktop.Sound.play(chime, volume: vol)
    {:noreply, put_flash(socket, :info, "Testing chime sound: #{chime}")}
  end

  @impl true
  def handle_event("save_model_override", %{"override" => override_params}, socket) do
    model = String.trim(override_params["model"] || "")

    if model == "" do
      {:noreply, put_flash(socket, :error, "Model name cannot be blank")}
    else
      existing = socket.assigns.settings.model_overrides || %{}

      config =
        %{}
        |> maybe_put_override("reasoning_effort", override_params["reasoning_effort"])
        |> maybe_put_override_int("budget_tokens", override_params["budget_tokens"])
        |> maybe_put_override_int("max_tokens", override_params["max_tokens"])
        |> maybe_put_override_float("temperature", override_params["temperature"])

      updated_overrides = Map.put(existing, model, config)

      case Settings.update_settings(%{model_overrides: updated_overrides}) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> assign_saved(updated, "Model override for #{model} saved")
           |> put_flash(:info, "Saved override for #{model}")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to save model override")}
      end
    end
  end

  @impl true
  def handle_event("delete_model_override", %{"model" => model}, socket) do
    existing = socket.assigns.settings.model_overrides || %{}
    updated_overrides = Map.delete(existing, model)

    case Settings.update_settings(%{model_overrides: updated_overrides}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign_saved(updated, "Override for #{model} removed")
         |> put_flash(:info, "Removed override for #{model}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to remove model override")}
    end
  end

  @impl true
  def handle_info({:local_models_discovered, _models}, socket) do
    status =
      if Code.ensure_loaded?(IexCode.LLM.Discovery.Server) and
           Process.whereis(IexCode.LLM.Discovery.Server) do
        IexCode.LLM.Discovery.Server.get_status()
      else
        socket.assigns.local_servers_status
      end

    {:noreply,
     socket
     |> assign(:local_servers_status, status)
     |> assign(:scanning_local_models?, false)}
  end

  @impl true
  def handle_info({:settings_updated, updated}, socket) do
    cond do
      same_settings_version?(socket.assigns.settings, updated) ->
        # The subscriber also receives its own successful write. Preserve the
        # more specific local status message (for example, provider order).
        {:noreply, socket}

      socket.assigns.settings_status in [:dirty, :error] ->
        {:noreply, assign(socket, :external_update?, true)}

      true ->
        {:noreply, assign_saved(socket, updated, "Settings updated")}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  def provider_id(descriptor), do: descriptor.id |> Atom.to_string()

  def settings_sections, do: @settings_sections

  def settings_sections(tab_id) do
    Enum.filter(@settings_sections, fn {section_id, _label} ->
      Map.fetch!(@section_tabs, section_id) == tab_id
    end)
  end

  def appearance_themes, do: @appearance_themes

  def appearance_theme(form) do
    case form[:ui_theme].value do
      theme when theme in @appearance_theme_ids -> theme
      _theme -> "midnight"
    end
  end

  def appearance_enabled?(form, field) when field in [:shadows_3d, :effects_3d] do
    form[field].value in [true, "true", "1", "on", 1]
  end

  def appearance_theme_errors(form) do
    Enum.map(form[:ui_theme].errors, &translate_error/1)
  end

  attr :id, :string, required: true
  attr :eyebrow, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :tone, :string, default: "default"

  def settings_section_header(assigns) do
    ~H"""
    <header class="settings-section-header">
      <h3 id={@id}>{@title}</h3>
      <p>{@description}</p>
    </header>
    """
  end

  attr :configured, :boolean, required: true

  def credential_badge(assigns) do
    ~H"""
    <span class={[
      "settings-credential-badge shrink-0 border px-2 py-1 text-[11px] font-medium",
      if(@configured,
        do: "border-emerald-400/25 bg-emerald-400/[0.06] text-emerald-300",
        else: "border-line bg-inset text-subtle"
      )
    ]}>
      {if @configured, do: "Configured", else: "Not configured"}
    </span>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :description, :string, required: true
  attr :checked, :boolean, default: false

  def tool_checkbox(assigns) do
    ~H"""
    <label for={@id} class="settings-tool-choice">
      <input type="hidden" name={@name} value="false" />
      <input
        id={@id}
        type="checkbox"
        name={@name}
        value="true"
        checked={@checked}
        class="mt-0.5 h-4 w-4 shrink-0 accent-accent"
      />
      <span>
        <span class="block text-sm font-semibold text-content">{@label}</span>
        <span class="mt-1 block text-xs leading-5 text-muted">{@description}</span>
      </span>
    </label>
    """
  end

  def provider_name(descriptor) do
    descriptor.id
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def provider_config(form, settings, provider) do
    form_params = form_params(form)

    saved =
      settings.search_providers
      |> Kernel.||(%{})
      |> Map.get(provider, %{})
      |> normalize_provider_config()

    submitted =
      form_params
      |> Map.get("search_providers", %{})
      |> Map.get(provider)

    if is_map(submitted) do
      submitted
      |> normalize_provider_config()
      |> Enum.reject(fn
        {"api_key", value} when is_binary(value) -> String.trim(value) == ""
        _entry -> false
      end)
      |> Map.new()
      |> then(&Map.merge(saved, &1))
    else
      saved
    end
  end

  def provider_enabled?(config),
    do: Map.get(config, "enabled", Map.get(config, :enabled, false)) in [true, "true", "1", "on"]

  def credential_configured?(value), do: is_binary(value) and String.trim(value) != ""

  def credential_placeholder(value) do
    if credential_configured?(value),
      do: "Saved credential · enter a replacement",
      else: "Enter credential"
  end

  def tool_enabled?(form, settings, tool) do
    form_value =
      form
      |> form_params()
      |> Map.get("default_tools", %{})
      |> Map.get(tool)

    if is_nil(form_value) do
      settings.default_tools
      |> Kernel.||(%{})
      |> Map.get(tool, false)
    else
      form_value in [true, "true", "1", "on"]
    end
  end

  def provider_ready?(descriptor, config) do
    key_ready? =
      :api_key not in descriptor.config_fields or credential_configured?(config["api_key"])

    instance_ready? =
      descriptor.id != :searxng or credential_configured?(config["base_url"])

    engine_ready? =
      descriptor.id != :google or credential_configured?(config["engine_id"])

    descriptor.lifecycle != :retired and key_ready? and instance_ready? and engine_ready?
  end

  def provider_status(descriptor, config) do
    cond do
      descriptor.lifecycle == :retired -> {"Retired", "retired"}
      provider_ready?(descriptor, config) and provider_enabled?(config) -> {"Enabled", "enabled"}
      provider_ready?(descriptor, config) -> {"Configured", "configured"}
      true -> {"Needs setup", "missing"}
    end
  end

  def provider_lifecycle_note(%{lifecycle: :sunsetting, retires_at: date}),
    do: "Sunsets #{Date.to_iso8601(date)}. Keep a replacement enabled."

  def provider_lifecycle_note(%{lifecycle: :retired}),
    do: "Retained for compatibility only and excluded from new runs."

  def provider_lifecycle_note(%{lifecycle: :unofficial}),
    do: "Credential-free fallback with no official API contract."

  def provider_lifecycle_note(_descriptor), do: nil

  def filtered_descriptors(descriptors, filter) do
    filter = filter |> String.trim() |> String.downcase()

    if filter == "" do
      descriptors
    else
      Enum.filter(descriptors, fn descriptor ->
        haystack =
          [
            provider_name(descriptor),
            Atom.to_string(descriptor.lifecycle) | descriptor.capabilities
          ]
          |> Enum.map_join(" ", &to_string/1)
          |> String.downcase()

        String.contains?(haystack, filter)
      end)
    end
  end

  def provider_order(form, settings) do
    case Map.get(form_params(form), "search_provider_order") do
      order when is_list(order) and order != [] ->
        Enum.map(order, &to_string/1)

      order when is_binary(order) ->
        order
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> case do
          [] -> provider_order(settings)
          parsed -> parsed
        end

      _other ->
        provider_order(settings)
    end
  end

  def first_provider?(form, settings, provider),
    do: List.first(provider_order(form, settings)) == provider

  def last_provider?(form, settings, provider),
    do: List.last(provider_order(form, settings)) == provider

  def usage_value(row, key, default \\ nil), do: map_value(row, key, default)

  def usage_total_value(totals), do: max(map_value(totals, :tokens, 0), 0)

  def usage_cost_value(totals), do: max(map_value(totals, :cost_cents, 0), 0) / 100

  def format_usage_date(%DateTime{} = date), do: Calendar.strftime(date, "%b %d, %Y · %H:%M")
  def format_usage_date(%NaiveDateTime{} = date), do: Calendar.strftime(date, "%b %d, %Y · %H:%M")
  def format_usage_date(_date), do: "Unknown date"

  def research_effort_value(value) do
    case to_string(value || "medium") do
      "low" -> {"Low", "Fast evidence pass with conservative enforced ceilings."}
      "high" -> {"High", "Broad evidence gathering with verification and conflict review."}
      "ultra" -> {"Ultra", "Largest bounded investigation. Expect longer background execution."}
      _ -> {"Medium", "Balanced source coverage, verification, and runtime."}
    end
  end

  def optional_limit(value, _unit) when value in [nil, ""], do: "Preset ceiling"
  def optional_limit(value, unit), do: "#{value} #{unit}"

  def form_error_count(form) do
    form.source
    |> case do
      %Changeset{} = changeset ->
        Changeset.traverse_errors(changeset, fn {_message, _opts} -> :error end)
        |> count_errors()

      _ ->
        0
    end
  end

  def status_title(:dirty), do: "Unsaved changes"
  def status_title(:saved), do: "Saved"
  def status_title(:error), do: "Needs attention"
  def status_title(:saving), do: "Saving"
  def status_title(_status), do: "Up to date"

  def status_text_class(:dirty), do: "text-amber-300"
  def status_text_class(:saved), do: "text-emerald-300"
  def status_text_class(:error), do: "text-rose-300"
  def status_text_class(_status), do: "text-content"

  def usage_dom_id(row) do
    case usage_value(row, :id) do
      nil -> :erlang.phash2(row)
      id -> id
    end
  end

  defp count_errors(errors) when is_map(errors) do
    Enum.reduce(errors, 0, fn {_key, value}, count -> count + count_errors(value) end)
  end

  defp count_errors(errors) when is_list(errors), do: max(length(errors), 1)
  defp count_errors(_errors), do: 0

  defp load_context_session(nil), do: nil

  defp load_context_session(id) do
    Sessions.get_session(id)
  rescue
    _ -> nil
  end

  defp return_path(nil), do: ~p"/"
  defp return_path(session), do: ~p"/sessions/#{session.id}"

  defp settings_form(settings), do: Settings.change_settings(settings) |> to_form(as: :settings)

  defp draft_changeset(settings, params) do
    settings
    |> Settings.change_settings(normalize_form_params(params, settings))
    |> Map.put(:action, :validate)
  end

  defp normalize_form_params(params, settings) do
    if function_exported?(Settings, :normalize_form_params, 2) do
      apply(Settings, :normalize_form_params, [params, settings])
    else
      params
    end
  end

  defp update_from_form(settings, params) do
    if function_exported?(Settings, :update_settings_from_form, 2) do
      apply(Settings, :update_settings_from_form, [settings, params])
    else
      Settings.update_settings(normalize_form_params(params, settings))
    end
  end

  defp assign_saved(socket, updated, message) do
    socket
    |> assign(:settings, updated)
    |> assign(:settings_form, settings_form(updated))
    |> assign(:search_provider_descriptors, ordered_descriptors(updated))
    |> assign(:settings_status, :saved)
    |> assign(:settings_message, message)
    |> assign(:saved_at, DateTime.utc_now())
    |> assign(:external_update?, false)
    |> push_event("settings_clear_secrets", %{})
  end

  defp assign_save_error(socket, message, params) do
    socket
    |> assign(
      :settings_form,
      to_form(draft_changeset(socket.assigns.settings, params), as: :settings)
    )
    |> assign(:settings_status, :error)
    |> assign(:settings_message, message)
  end

  defp assign_cleared_credential(socket, updated, draft_params, credential_key) do
    draft_params = drop_cleared_credential(draft_params, credential_key)

    if socket.assigns.settings_status in [:dirty, :error] and map_size(draft_params) > 0 do
      changeset = draft_changeset(updated, draft_params)
      status = if changeset.valid?, do: :dirty, else: :error

      message =
        if changeset.valid?,
          do: "Credential removed. Your other edits remain unsaved.",
          else: "Credential removed. Your invalid draft is preserved for review."

      socket
      |> assign(:settings, updated)
      |> assign(:settings_form, to_form(changeset, as: :settings))
      |> assign(
        :search_provider_descriptors,
        ordered_descriptors(provider_order(to_form(changeset, as: :settings), updated))
      )
      |> assign(:settings_status, status)
      |> assign(:settings_message, message)
      |> assign(:saved_at, DateTime.utc_now())
      |> assign(:external_update?, false)
      |> push_event("settings_clear_secrets", %{})
    else
      assign_saved(socket, updated, "Credential removed")
    end
  end

  defp assign_reordered_draft(socket, draft_params, new_order) do
    changeset = draft_changeset(socket.assigns.settings, draft_params)
    status = if changeset.valid?, do: :dirty, else: :error

    message =
      if changeset.valid?,
        do: "Provider order changed. Save to apply it.",
        else: "Provider order changed in this draft. Review the highlighted fields before saving."

    socket
    |> assign(:settings_form, to_form(changeset, as: :settings))
    |> assign(:search_provider_descriptors, ordered_descriptors(new_order))
    |> assign(:settings_status, status)
    |> assign(:settings_message, message)
  end

  defp drop_cleared_credential(params, :openai), do: Map.delete(params, "openai_api_key")
  defp drop_cleared_credential(params, :anthropic), do: Map.delete(params, "anthropic_api_key")

  defp drop_cleared_credential(params, {:search, provider}) do
    case Map.get(params, "search_providers") do
      providers when is_map(providers) ->
        config = providers |> Map.get(provider, %{}) |> Map.delete("api_key")
        Map.put(params, "search_providers", Map.put(providers, provider, config))

      _providers ->
        params
    end
  end

  defp database_error(_reason),
    do: "The local settings database could not save this change. Try again."

  defp save_error({:db_error, reason}), do: database_error(reason)
  defp save_error(_reason), do: "Settings could not be saved. Your edits are still here."

  defp credential_key("openai"), do: {:ok, :openai}
  defp credential_key("anthropic"), do: {:ok, :anthropic}

  defp credential_key("provider:" <> provider) do
    if provider in Enum.map(SearchRegistry.names(), &Atom.to_string/1) do
      {:ok, {:search, provider}}
    else
      {:error, :unknown_credential}
    end
  end

  defp credential_key(_credential), do: {:error, :unknown_credential}

  defp ordered_descriptors(settings) when is_map(settings) do
    ordered_descriptors(provider_order(settings))
  end

  defp ordered_descriptors(order) when is_list(order) do
    by_id = Map.new(SearchRegistry.descriptors(), &{provider_id(&1), &1})

    order
    |> Enum.flat_map(fn id -> if descriptor = by_id[id], do: [descriptor], else: [] end)
  end

  defp provider_order(settings) do
    settings.search_provider_order || Enum.map(SearchRegistry.names(), &Atom.to_string/1)
  end

  defp move_in_order(order, provider, direction) do
    index = Enum.find_index(order, &(&1 == provider))
    destination = if direction == "up", do: index - 1, else: index + 1

    if destination in 0..(length(order) - 1) do
      other = Enum.at(order, destination)

      order
      |> List.replace_at(index, other)
      |> List.replace_at(destination, provider)
    else
      order
    end
  end

  defp toggle_set_member(set, value) do
    if MapSet.member?(set, value), do: MapSet.delete(set, value), else: MapSet.put(set, value)
  end

  defp form_params(%Phoenix.HTML.Form{params: params}) when is_map(params), do: params
  defp form_params(_form), do: %{}

  defp normalize_provider_config(config) do
    Map.new(config, fn {key, value} -> {to_string(key), value} end)
  end

  defp load_usage(session) do
    source = Application.get_env(:iex_code, :usage_reader, Sessions)
    opts = if session, do: [session_id: session.id], else: [scope: :global]

    empty_message =
      if session,
        do: "No provider-reported usage has been recorded for this session yet.",
        else: "No provider-reported usage has been recorded yet."

    with {:ok, rows} <- usage_history(source, opts),
         {:ok, totals} <- usage_totals(source, opts) do
      {status, rows, message} = normalize_usage_result(rows, empty_message)
      {status, rows, totals, message}
    else
      {:error, :session_scope_unavailable} ->
        {:unavailable, [], %{}, "Session-scoped usage is unavailable in this build."}

      {:error, _reason} ->
        {:error, [], %{}, "Usage telemetry is temporarily unavailable."}
    end
  rescue
    _ -> {:error, [], %{}, "Usage telemetry is temporarily unavailable."}
  end

  defp usage_history(source, opts) do
    _ = Code.ensure_loaded(source)

    cond do
      function_exported?(source, :fetch_usage_history, 2) ->
        apply(source, :fetch_usage_history, [100, opts])

      function_exported?(source, :list_usage_history, 2) ->
        {:ok, apply(source, :list_usage_history, [100, opts])}

      true ->
        {:error, :session_scope_unavailable}
    end
  end

  defp usage_totals(source, opts) do
    _ = Code.ensure_loaded(source)

    cond do
      function_exported?(source, :fetch_usage_totals, 1) ->
        apply(source, :fetch_usage_totals, [opts])

      function_exported?(source, :usage_totals, 1) ->
        {:ok, apply(source, :usage_totals, [opts])}

      true ->
        {:error, :usage_totals_unavailable}
    end
  end

  defp normalize_usage_result({:ok, rows}, empty_message) when is_list(rows),
    do: normalize_usage_result(rows, empty_message)

  defp normalize_usage_result({:error, :session_scope_unavailable}, _empty_message),
    do: {:unavailable, [], "Session-scoped usage is unavailable in this build."}

  defp normalize_usage_result({:error, _reason}, _empty_message),
    do: {:error, [], "Usage telemetry is temporarily unavailable."}

  defp normalize_usage_result(rows, empty_message) when is_list(rows) do
    rows = Enum.filter(rows, &(map_value(&1, :tokens, 0) > 0))
    if rows == [], do: {:empty, [], empty_message}, else: {:ready, rows, nil}
  end

  defp normalize_usage_result(_rows, _empty_message),
    do: {:error, [], "Usage telemetry is temporarily unavailable."}

  defp runtime_facts do
    [
      %{
        id: "dispatcher",
        label: "Durable run dispatcher",
        value: online_label(IexCode.Runs.RunDispatcher),
        tone: online_tone(IexCode.Runs.RunDispatcher),
        note: "Background runs persist independently of this browser page."
      },
      %{
        id: "terminal",
        label: "Terminal supervisor",
        value: online_label(IexCode.Tools.TerminalSupervisor),
        tone: online_tone(IexCode.Tools.TerminalSupervisor),
        note: "Shell processes remain isolated by workspace and session ownership."
      },
      %{
        id: "database",
        label: "Settings storage",
        value: "Local SQLite",
        tone: "ready",
        note: "Credentials are stored locally and never rendered back into this page."
      }
    ]
  end

  defp online_label(module), do: if(Process.whereis(module), do: "Online", else: "Offline")
  defp online_tone(module), do: if(Process.whereis(module), do: "ready", else: "missing")

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default)) || default
  end

  defp map_value(_map, _key, default), do: default

  def studio_tabs, do: @studio_tabs

  def tab_icon(tab) do
    case Enum.find(@studio_tabs, fn {id, _label, _icon} -> id == to_string(tab) end) do
      {_id, _label, icon} -> icon
      nil -> "hero-adjustments-horizontal"
    end
  end

  def tab_title(:providers), do: "Providers & models"
  def tab_title(:reasoning), do: "Reasoning"
  def tab_title(:safety), do: "Execution & safety"
  def tab_title(:context), do: "Context & research"
  def tab_title(:environment), do: "Environment"
  def tab_title(:appearance), do: "Appearance & sound"
  def tab_title(tab), do: Phoenix.Naming.humanize(to_string(tab))

  def tab_description(:providers), do: "Connect your models and choose defaults for new sessions."

  def tab_description(:reasoning),
    do: "Balance thinking effort, response limits, and model-specific behavior."

  def tab_description(:safety), do: "Choose how agents run, what they can do, and when they ask."

  def tab_description(:context),
    do: "Manage conversation memory, instructions, and research limits."

  def tab_description(:environment), do: "Review the environment available to agent tools."
  def tab_description(:appearance), do: "Make the workspace comfortable for the way you work."

  def tab_path(nil, tab_id), do: ~p"/settings/#{tab_id}"
  def tab_path(session, tab_id), do: ~p"/sessions/#{session.id}/settings/#{tab_id}"

  def section_path(session, section_id) do
    tab_id = Map.fetch!(@section_tabs, section_id)
    tab_path(session, tab_id) <> "#" <> section_id
  end

  defp maybe_put_override(map, _key, val) when val in [nil, "", "default"], do: map
  defp maybe_put_override(map, key, val), do: Map.put(map, key, val)

  defp maybe_put_override_int(map, _key, val) when val in [nil, ""], do: map

  defp maybe_put_override_int(map, key, val) when is_binary(val) do
    case Integer.parse(val) do
      {int, ""} -> Map.put(map, key, int)
      _ -> map
    end
  end

  defp maybe_put_override_int(map, key, val) when is_integer(val), do: Map.put(map, key, val)

  defp maybe_put_override_float(map, _key, val) when val in [nil, ""], do: map

  defp maybe_put_override_float(map, key, val) when is_binary(val) do
    case Float.parse(val) do
      {flt, ""} -> Map.put(map, key, flt)
      _ -> map
    end
  end

  defp maybe_put_override_float(map, key, val) when is_float(val), do: Map.put(map, key, val)

  defp maybe_put_override_float(map, key, val) when is_integer(val),
    do: Map.put(map, key, val * 1.0)

  defp same_settings_version?(left, right) do
    left == right
  end
end

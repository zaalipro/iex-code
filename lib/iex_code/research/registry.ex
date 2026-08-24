defmodule IexCode.Research.Registry do
  @moduledoc """
  Canonical registry and configuration resolver for search providers.

  Provider descriptors expose operational lifecycle, capability, and
  authentication metadata without requiring callers to load provider modules.
  Retired providers remain addressable for an explicit compatibility request,
  but are excluded from configuration-driven automatic selection.
  """

  @descriptor_order ~w(tavily brave exa serper google bing searxng duckduckgo)a

  @descriptors %{
    tavily: %{
      id: :tavily,
      module: IexCode.Research.Providers.Tavily,
      lifecycle: :active,
      capabilities: [:web_search, :content],
      auth_label: "API key"
    },
    brave: %{
      id: :brave,
      module: IexCode.Research.Providers.Brave,
      lifecycle: :active,
      capabilities: [:web_search],
      auth_label: "Subscription token"
    },
    exa: %{
      id: :exa,
      module: IexCode.Research.Providers.Exa,
      lifecycle: :active,
      capabilities: [:web_search, :semantic_search, :content],
      auth_label: "API key"
    },
    serper: %{
      id: :serper,
      module: IexCode.Research.Providers.Serper,
      lifecycle: :active,
      capabilities: [:web_search],
      auth_label: "API key"
    },
    google: %{
      id: :google,
      module: IexCode.Research.Providers.GoogleCSE,
      lifecycle: :legacy,
      capabilities: [:web_search],
      auth_label: "API key + search engine ID"
    },
    bing: %{
      id: :bing,
      module: IexCode.Research.Providers.Bing,
      lifecycle: :retired,
      capabilities: [:web_search],
      auth_label: "Subscription key"
    },
    searxng: %{
      id: :searxng,
      module: IexCode.Research.Providers.SearxNG,
      lifecycle: :active,
      capabilities: [:web_search, :metasearch, :self_hosted],
      auth_label: "Instance URL"
    },
    duckduckgo: %{
      id: :duckduckgo,
      module: IexCode.Research.Providers.DuckDuckGo,
      lifecycle: :unofficial,
      capabilities: [:web_search, :credential_free],
      auth_label: "No credentials"
    }
  }

  @providers Map.new(@descriptors, fn {id, descriptor} -> {id, descriptor.module} end)

  @type lifecycle :: :active | :legacy | :retired | :unofficial
  @type descriptor :: %{
          id: atom(),
          module: module(),
          lifecycle: lifecycle(),
          capabilities: [atom()],
          auth_label: String.t()
        }

  @doc "Returns the provider module map retained for backwards compatibility."
  def all, do: @providers

  @doc "Returns provider identifiers in their stable presentation order."
  def names, do: @descriptor_order

  @doc "Returns provider descriptors in their stable presentation order."
  @spec descriptors() :: [descriptor()]
  def descriptors, do: Enum.map(@descriptor_order, &Map.fetch!(@descriptors, &1))

  @doc "Looks up lifecycle, capability, and authentication metadata for a provider."
  @spec descriptor(atom() | String.t()) :: {:ok, descriptor()} | :error
  def descriptor(name) do
    with {:ok, id} <- normalize_name(name) do
      Map.fetch(@descriptors, id)
    end
  end

  @doc "Returns whether configuration-driven selection may use the provider."
  @spec automatically_selectable?(atom() | String.t()) :: boolean()
  def automatically_selectable?(name) do
    case descriptor(name) do
      {:ok, %{lifecycle: :retired}} -> false
      {:ok, _descriptor} -> true
      :error -> match?({:ok, _module}, fetch_custom_module(name))
    end
  end

  def fetch(name) do
    with {:ok, id} <- normalize_name(name) do
      Map.fetch(@providers, id)
    else
      :error -> fetch_custom_module(name)
    end
  end

  def configured(config \\ %{}) when is_map(config) do
    order = configured_order(config)
    config = unwrap_config(config)

    if map_size(config) == 0 do
      [{:duckduckgo, @providers.duckduckgo, %{}}]
    else
      order
      |> Enum.flat_map(fn name ->
        with {:ok, module} <- fetch(name),
             true <- configured_selectable?(name),
             provider_config <- provider_config(config, name),
             true <- enabled?(provider_config) do
          [{provider_name(name), module, provider_config}]
        else
          _ -> []
        end
      end)
    end
  end

  def configured_providers(settings_or_config), do: configured(settings_or_config)

  def provider_config(config, name) do
    config = unwrap_config(config)

    case Map.get(config, name) || Map.get(config, provider_key(name)) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  # DuckDuckGo is the useful, credential-free baseline only when no provider
  # configuration exists. A populated configuration is strictly opt-in.
  defp enabled?(config),
    do: Map.get(config, :enabled, Map.get(config, "enabled", false)) == true

  defp unwrap_config(%{search_providers: config}) when is_map(config), do: config
  defp unwrap_config(%{"search_providers" => config}) when is_map(config), do: config
  defp unwrap_config(%{providers: config}) when is_map(config), do: config
  defp unwrap_config(%{"providers" => config}) when is_map(config), do: config
  defp unwrap_config(config), do: config

  defp configured_order(%{search_provider_order: order}) when is_list(order), do: order
  defp configured_order(%{"search_provider_order" => order}) when is_list(order), do: order
  defp configured_order(%{order: order}) when is_list(order), do: order
  defp configured_order(%{"order" => order}) when is_list(order), do: order
  defp configured_order(config), do: config |> unwrap_config() |> Map.keys()

  defp provider_name(name) do
    case normalize_name(name) do
      {:ok, id} -> id
      :error -> name
    end
  end

  defp provider_key(name) when is_atom(name), do: Atom.to_string(name)
  defp provider_key(name) when is_binary(name), do: name
  defp provider_key(name), do: to_string(name)

  defp normalize_name(:google_cse), do: {:ok, :google}
  defp normalize_name("google_cse"), do: {:ok, :google}

  defp normalize_name(name) when is_atom(name) do
    if Map.has_key?(@descriptors, name), do: {:ok, name}, else: :error
  end

  defp normalize_name(name) when is_binary(name) do
    Enum.find_value(@descriptor_order, :error, fn id ->
      if Atom.to_string(id) == name, do: {:ok, id}
    end)
  end

  defp normalize_name(_name), do: :error

  defp fetch_custom_module(name) when is_atom(name) do
    if Code.ensure_loaded?(name) and function_exported?(name, :search, 2),
      do: {:ok, name},
      else: :error
  end

  defp fetch_custom_module(_name), do: :error

  defp configured_selectable?(name), do: automatically_selectable?(name)
end

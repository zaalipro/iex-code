defmodule IexCode.Research.Registry do
  @moduledoc "Canonical registry and configuration resolver for search providers."

  @providers %{
    duckduckgo: IexCode.Research.Providers.DuckDuckGo,
    tavily: IexCode.Research.Providers.Tavily,
    brave: IexCode.Research.Providers.Brave,
    exa: IexCode.Research.Providers.Exa,
    serper: IexCode.Research.Providers.Serper,
    searxng: IexCode.Research.Providers.SearxNG,
    google: IexCode.Research.Providers.GoogleCSE,
    bing: IexCode.Research.Providers.Bing
  }

  def all, do: @providers
  def names, do: Map.keys(@providers)

  def fetch("google_cse"), do: Map.fetch(@providers, :google)

  def fetch(name) when is_binary(name),
    do:
      Enum.find_value(@providers, :error, fn {key, module} ->
        if Atom.to_string(key) == name, do: {:ok, module}
      end)

  def fetch(name) when is_atom(name) do
    name = if name == :google_cse, do: :google, else: name

    case Map.fetch(@providers, name) do
      {:ok, module} -> {:ok, module}
      :error -> if(function_exported?(name, :search, 2), do: {:ok, name}, else: :error)
    end
  end

  def fetch(_name), do: :error

  def configured(config \\ %{}) when is_map(config) do
    order = configured_order(config)
    config = unwrap_config(config)

    if map_size(config) == 0 do
      [{:duckduckgo, @providers.duckduckgo, %{}}]
    else
      order
      |> Enum.flat_map(fn name ->
        with {:ok, module} <- fetch(name),
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

    case Map.get(config, name) || Map.get(config, Atom.to_string(name)) do
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

  defp provider_name(name) when is_atom(name), do: name

  defp provider_name(name) do
    Enum.find(names(), name, &(Atom.to_string(&1) == name))
  end
end

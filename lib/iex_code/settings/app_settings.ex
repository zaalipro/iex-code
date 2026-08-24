defmodule IexCode.Settings.AppSettings do
  use Ecto.Schema
  import Ecto.Changeset

  alias IexCode.Research.Registry, as: SearchRegistry

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "app_settings" do
    field :anthropic_api_key, :string, redact: true
    field :anthropic_base_url, :string, default: "https://api.anthropic.com"
    field :openai_api_key, :string, redact: true
    field :openai_base_url, :string, default: "https://api.openai.com/v1"
    field :default_model_provider, :string, default: "anthropic"
    field :default_model, :string, default: "claude-3-7-sonnet"
    field :swarm_agent_count, :integer, default: 4
    field :auto_save, :boolean, default: true
    field :temperature, :float, default: 0.2
    field :max_tokens, :integer, default: 4096

    field :search_providers, :map,
      redact: true,
      default: %{
        "tavily" => %{"enabled" => false},
        "brave" => %{"enabled" => false},
        "exa" => %{"enabled" => false},
        "perplexity" => %{"enabled" => false},
        "firecrawl" => %{"enabled" => false},
        "linkup" => %{"enabled" => false},
        "serper" => %{"enabled" => false},
        "serpapi" => %{"enabled" => false},
        "google" => %{"enabled" => false},
        "bing" => %{"enabled" => false},
        "searxng" => %{"enabled" => false},
        "duckduckgo" => %{"enabled" => true}
      }

    field :search_provider_order, {:array, :string},
      default:
        ~w(tavily brave exa perplexity firecrawl linkup serper serpapi google bing searxng duckduckgo)

    field :research_depth, :string, default: "standard"
    field :research_max_sources, :integer, default: 12
    field :research_parallelism, :integer, default: 4

    timestamps(type: :utc_datetime)
  end

  @model_providers ~w(openai anthropic)
  @search_provider_ids ~w(tavily brave exa perplexity firecrawl linkup serper serpapi google bing searxng duckduckgo)

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [
      :anthropic_api_key,
      :anthropic_base_url,
      :openai_api_key,
      :openai_base_url,
      :default_model_provider,
      :default_model,
      :swarm_agent_count,
      :auto_save,
      :temperature,
      :max_tokens,
      :search_providers,
      :search_provider_order,
      :research_depth,
      :research_max_sources,
      :research_parallelism
    ])
    |> validate_inclusion(:default_model_provider, @model_providers)
    |> validate_number(:swarm_agent_count,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 32
    )
    |> validate_number(:temperature,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 2.0
    )
    |> validate_number(:max_tokens,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 128_000
    )
    |> validate_inclusion(:research_depth, ~w(quick standard deep))
    |> validate_number(:research_max_sources,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 100
    )
    |> validate_number(:research_parallelism,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 16
    )
    |> validate_search_providers()
    |> validate_search_provider_order()
  end

  defp validate_search_providers(changeset) do
    case get_field(changeset, :search_providers) do
      providers when is_map(providers) and map_size(providers) <= 32 ->
        encoded_size = providers |> Jason.encode!() |> byte_size()

        if encoded_size <= 64_000 and Enum.all?(providers, &valid_provider_config?/1) do
          changeset
        else
          add_error(changeset, :search_providers, "contains an invalid provider configuration")
        end

      _ ->
        add_error(changeset, :search_providers, "must be a map with at most 32 providers")
    end
  end

  defp valid_provider_config?({id, config}) when is_binary(id) and is_map(config) do
    keys = Enum.map(Map.keys(config), &to_string/1)

    id in @search_provider_ids and valid_provider_fields?(id, keys) and
      valid_enabled?(Map.get(config, "enabled", Map.get(config, :enabled))) and
      valid_bounded_string?(Map.get(config, "api_key", Map.get(config, :api_key)), 4_096) and
      valid_bounded_string?(Map.get(config, "engine_id", Map.get(config, :engine_id)), 500) and
      valid_engine?(id, Map.get(config, "engine", Map.get(config, :engine))) and
      valid_provider_url?(id, Map.get(config, "base_url", Map.get(config, :base_url)))
  end

  defp valid_provider_config?(_), do: false

  defp valid_provider_fields?(id, fields) do
    case SearchRegistry.descriptor(id) do
      {:ok, descriptor} ->
        allowed = Enum.map(descriptor.config_fields, &Atom.to_string/1)
        Enum.all?(fields, &(&1 in allowed))

      :error ->
        false
    end
  end

  defp valid_enabled?(value), do: is_nil(value) or is_boolean(value)

  defp valid_bounded_string?(value, max),
    do: is_nil(value) or (is_binary(value) and byte_size(value) <= max)

  defp valid_engine?("serpapi", value),
    do: is_nil(value) or value in ~w(google bing duckduckgo baidu yahoo yandex)

  defp valid_engine?(_id, value), do: is_nil(value)

  defp valid_provider_url?(_id, value) when value in [nil, ""], do: true

  defp valid_provider_url?(id, value) when is_binary(value) and byte_size(value) <= 2_048 do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        if id == "searxng" do
          true
        else
          scheme == "https" and SearchRegistry.official_host(id) == String.downcase(host)
        end

      _ ->
        false
    end
  end

  defp valid_provider_url?(_id, _value), do: false

  defp validate_search_provider_order(changeset) do
    order = get_field(changeset, :search_provider_order)
    providers = get_field(changeset, :search_providers) || %{}

    if is_list(order) and order != [] and length(order) <= 32 and
         Enum.all?(order, &(is_binary(&1) and Map.has_key?(providers, &1))) and
         length(Enum.uniq(order)) == length(order) do
      changeset
    else
      add_error(
        changeset,
        :search_provider_order,
        "must contain unique configured provider identifiers"
      )
    end
  end
end

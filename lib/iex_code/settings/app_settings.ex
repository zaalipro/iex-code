defmodule IexCode.Settings.AppSettings do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "app_settings" do
    field :anthropic_api_key, :string
    field :anthropic_base_url, :string, default: "https://api.anthropic.com"
    field :openai_api_key, :string
    field :openai_base_url, :string, default: "https://api.openai.com/v1"
    field :default_model_provider, :string, default: "anthropic"
    field :default_model, :string, default: "claude-3-7-sonnet"
    field :swarm_agent_count, :integer, default: 4
    field :auto_save, :boolean, default: true
    field :temperature, :float, default: 0.2
    field :max_tokens, :integer, default: 4096

    timestamps(type: :utc_datetime)
  end

  @model_providers ~w(openai anthropic)

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
      :max_tokens
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
  end
end

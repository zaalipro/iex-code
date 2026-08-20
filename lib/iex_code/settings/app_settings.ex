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

    timestamps(type: :utc_datetime)
  end

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
      :auto_save
    ])
  end
end

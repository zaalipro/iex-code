defmodule IexCode.Sessions.Session do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sessions" do
    field :title, :string
    field :swarm_mode, :boolean, default: false
    field :model_provider, :string, default: "openai"
    field :model_name, :string, default: "gemini-3.7-flash-high"
    field :temperature, :float, default: 0.2
    field :status, :string, default: "idle"

    belongs_to :project, IexCode.Projects.Project
    has_many :messages, IexCode.Sessions.Message
    has_many :operations, IexCode.Sessions.Operation

    timestamps(type: :utc_datetime)
  end

  @statuses ~w(idle running paused stopped failed completed)
  @model_providers ~w(openai anthropic)

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :project_id,
      :title,
      :swarm_mode,
      :model_provider,
      :model_name,
      :temperature,
      :status
    ])
    |> validate_required([:project_id, :title])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:model_provider, @model_providers)
    |> foreign_key_constraint(:project_id)
  end

  def statuses, do: @statuses
end

defmodule IexCode.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projects" do
    field :name, :string
    field :root_path, :string
    field :description, :string
    field :last_opened_at, :utc_datetime

    has_many :sessions, IexCode.Sessions.Session
    has_many :workflows, IexCode.Workflows.Workflow
    has_many :workflow_runs, IexCode.Workflows.WorkflowRun

    timestamps(type: :utc_datetime)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :root_path, :description, :last_opened_at])
    |> validate_required([:name, :root_path])
    |> unique_constraint(:root_path)
  end
end

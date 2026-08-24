defmodule IexCode.Runs.Run do
  @moduledoc "A durable asynchronous coding run."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(queued running paused completed failed cancelled interrupted)
  @modes ~w(single swarm workflow research)
  @kinds ~w(coding_swarm analysis deep_research)
  @priorities ~w(low normal high critical)

  schema "runs" do
    field :objective, :string
    field :kind, :string, default: "coding_swarm"
    field :status, :string, default: "queued"
    field :mode, :string, default: "swarm"
    field :priority, :string, default: "normal"
    field :progress, :integer, default: 0
    field :event_sequence, :integer, default: 0
    field :control_sequence, :integer, default: 0
    field :token_budget, :integer
    field :cost_budget_cents, :integer
    field :time_budget_ms, :integer
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :cost_cents, :integer, default: 0
    field :metadata, :map, default: %{}
    field :error_message, :string
    field :error_details, :map
    field :started_at, :utc_datetime
    field :heartbeat_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime
    field :cancellation_requested_at, :utc_datetime
    field :not_before, :utc_datetime
    field :attempt, :integer, default: 0
    field :max_attempts, :integer, default: 3

    belongs_to :project, IexCode.Projects.Project
    belongs_to :session, IexCode.Sessions.Session
    has_many :steps, IexCode.Runs.RunStep
    has_many :events, IexCode.Runs.RunEvent
    has_many :commands, IexCode.Runs.RunCommand
    has_many :approvals, IexCode.Runs.RunApproval
    has_many :artifacts, IexCode.Runs.RunArtifact
    has_many :controls, IexCode.Runs.RunControl

    timestamps(type: :utc_datetime)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :objective,
      :kind,
      :status,
      :mode,
      :priority,
      :progress,
      :token_budget,
      :cost_budget_cents,
      :time_budget_ms,
      :input_tokens,
      :output_tokens,
      :cost_cents,
      :metadata,
      :error_message,
      :error_details,
      :started_at,
      :heartbeat_at,
      :completed_at,
      :lease_owner,
      :lease_expires_at,
      :cancellation_requested_at,
      :not_before,
      :attempt,
      :max_attempts
    ])
    |> validate_required([:project_id, :session_id, :objective, :kind, :status, :mode, :priority])
    |> validate_length(:objective, min: 1, max: 100_000)
    |> validate_length(:error_message, max: 20_000)
    |> validate_length(:lease_owner, max: 200)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:priority, @priorities)
    |> validate_number(:progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_nonnegative_optional(:token_budget)
    |> validate_nonnegative_optional(:cost_budget_cents)
    |> validate_nonnegative_optional(:time_budget_ms)
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:cost_cents, greater_than_or_equal_to: 0)
    |> validate_number(:attempt, greater_than_or_equal_to: 0)
    |> validate_number(:max_attempts, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)
    |> validate_attempts()
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:session_id)
  end

  def statuses, do: @statuses
  def modes, do: @modes
  def kinds, do: @kinds
  def priorities, do: @priorities

  defp validate_attempts(changeset) do
    attempt = get_field(changeset, :attempt)
    max_attempts = get_field(changeset, :max_attempts)

    if is_integer(attempt) and is_integer(max_attempts) and attempt > max_attempts do
      add_error(changeset, :attempt, "cannot exceed max_attempts")
    else
      changeset
    end
  end

  defp validate_nonnegative_optional(changeset, field) do
    validate_number(changeset, field, greater_than_or_equal_to: 0)
  end
end

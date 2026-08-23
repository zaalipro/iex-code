defmodule IexCode.Runs.RunApproval do
  @moduledoc "A durable human approval checkpoint for a run action."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending approved denied expired cancelled)

  schema "run_approvals" do
    field :key, :string
    field :action, :string
    field :resource, :string
    field :reason, :string
    field :status, :string, default: "pending"
    field :requested_by, :string, default: "system"
    field :decided_by, :string
    field :decision_note, :string
    field :metadata, :map, default: %{}
    field :expires_at, :utc_datetime
    field :decided_at, :utc_datetime

    belongs_to :run, IexCode.Runs.Run
    belongs_to :run_command, IexCode.Runs.RunCommand

    timestamps(type: :utc_datetime)
  end

  def changeset(approval, attrs) do
    approval
    |> cast(attrs, [
      :run_command_id,
      :key,
      :action,
      :resource,
      :reason,
      :status,
      :requested_by,
      :decided_by,
      :decision_note,
      :metadata,
      :expires_at,
      :decided_at
    ])
    |> validate_required([:run_id, :key, :action, :reason, :status, :requested_by])
    |> validate_length(:key, min: 1, max: 200)
    |> validate_format(:key, ~r/^[A-Za-z0-9][A-Za-z0-9._:-]*$/)
    |> validate_length(:action, min: 1, max: 120)
    |> validate_length(:resource, max: 2_000)
    |> validate_length(:reason, min: 1, max: 20_000)
    |> validate_length(:requested_by, min: 1, max: 160)
    |> validate_length(:decided_by, max: 160)
    |> validate_length(:decision_note, max: 20_000)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:run_id, :key])
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:run_command_id)
  end

  def statuses, do: @statuses
end

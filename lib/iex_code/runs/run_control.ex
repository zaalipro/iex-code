defmodule IexCode.Runs.RunControl do
  @moduledoc """
  A durable, ordered request to control a running coding run.

  Controls are idempotent within a run and move from `pending` through a
  worker claim to a durable outcome. A pending control may also be superseded
  before a worker claims it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(pause resume cancel steer)
  @statuses ~w(pending claimed applied rejected superseded)
  @terminal_statuses ~w(applied rejected superseded)

  schema "run_controls" do
    field :idempotency_key, :string
    field :sequence, :integer
    field :kind, :string
    field :status, :string, default: "pending"
    field :payload, :map, default: %{}
    field :result, :map
    field :requested_by, :string, default: "local-user"
    field :worker_id, :string
    field :claimed_at, :utc_datetime
    field :applied_at, :utc_datetime

    belongs_to :run, IexCode.Runs.Run

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(control, attrs) do
    control
    |> cast(attrs, [
      :idempotency_key,
      :sequence,
      :kind,
      :status,
      :payload,
      :result,
      :requested_by,
      :worker_id,
      :claimed_at,
      :applied_at
    ])
    |> validate_required([
      :run_id,
      :idempotency_key,
      :sequence,
      :kind,
      :status,
      :payload,
      :requested_by
    ])
    |> validate_length(:idempotency_key, min: 1, max: 200)
    |> validate_format(:idempotency_key, ~r/^[^\s]+$/)
    |> validate_number(:sequence, greater_than: 0)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:requested_by, min: 1, max: 160)
    |> validate_length(:worker_id, min: 1, max: 200)
    |> validate_lifecycle()
    |> validate_timestamp_order()
    |> unique_constraint([:run_id, :idempotency_key])
    |> unique_constraint([:run_id, :sequence])
    |> foreign_key_constraint(:run_id)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses
  def terminal_statuses, do: @terminal_statuses

  defp validate_lifecycle(changeset) do
    case get_field(changeset, :status) do
      "pending" ->
        changeset
        |> require_absent(:worker_id, "must be empty while pending")
        |> require_absent(:claimed_at, "must be empty while pending")
        |> require_absent(:applied_at, "must be empty while pending")
        |> require_absent(:result, "must be empty while pending")

      "claimed" ->
        changeset
        |> require_present(:worker_id, "is required when claimed")
        |> require_present(:claimed_at, "is required when claimed")
        |> require_absent(:applied_at, "must be empty while claimed")
        |> require_absent(:result, "must be empty while claimed")

      status when status in ~w(applied rejected) ->
        changeset
        |> require_present(:worker_id, "is required when #{status}")
        |> require_present(:claimed_at, "is required when #{status}")
        |> require_present(:applied_at, "is required when #{status}")
        |> require_present(:result, "is required when #{status}")

      "superseded" ->
        changeset
        |> require_present(:applied_at, "is required when superseded")
        |> require_present(:result, "is required when superseded")
        |> validate_claim_pair()

      _status ->
        changeset
    end
  end

  defp validate_claim_pair(changeset) do
    worker_id = get_field(changeset, :worker_id)
    claimed_at = get_field(changeset, :claimed_at)

    cond do
      present?(worker_id) and is_nil(claimed_at) ->
        add_error(changeset, :claimed_at, "is required when worker_id is set")

      not present?(worker_id) and not is_nil(claimed_at) ->
        add_error(changeset, :worker_id, "is required when claimed_at is set")

      true ->
        changeset
    end
  end

  defp validate_timestamp_order(changeset) do
    case {get_field(changeset, :claimed_at), get_field(changeset, :applied_at)} do
      {%DateTime{} = claimed_at, %DateTime{} = applied_at} ->
        if DateTime.compare(applied_at, claimed_at) == :lt do
          add_error(changeset, :applied_at, "cannot be before claimed_at")
        else
          changeset
        end

      _timestamps ->
        changeset
    end
  end

  defp require_present(changeset, field, message) do
    if present?(get_field(changeset, field)),
      do: changeset,
      else: add_error(changeset, field, message)
  end

  defp require_absent(changeset, field, message) do
    if present?(get_field(changeset, field)),
      do: add_error(changeset, field, message),
      else: changeset
  end

  defp present?(value), do: value not in [nil, ""]
end

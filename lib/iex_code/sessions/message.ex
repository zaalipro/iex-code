defmodule IexCode.Sessions.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    # "user", "assistant", "system", "tool"
    field :role, :string
    field :agent_name, :string, default: "assistant"
    field :content, :string
    field :tool_calls, {:array, :map}
    field :metadata, :map

    belongs_to :session, IexCode.Sessions.Session

    timestamps(type: :utc_datetime)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:session_id, :role, :agent_name, :content, :tool_calls, :metadata])
    |> validate_required([:session_id, :role, :content])
    |> foreign_key_constraint(:session_id)
  end
end

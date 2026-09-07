defmodule IexCode.Execution.Intent do
  @moduledoc """
  A parsed, side-effect-free execution intent.

  Intents describe what the caller requested without deciding how it is
  persisted or launched.  The execution router is responsible for turning an
  intent and a policy snapshot into work.
  """

  @enforce_keys [:kind, :durability, :mode, :draft?, :raw_command, :source]
  defstruct [
    :kind,
    :objective,
    :durability,
    :mode,
    :level,
    :attachment_id,
    :raw_command,
    :source,
    :blueprint_pattern,
    draft?: false,
    boost?: false,
    teamwork?: false
  ]

  @type kind ::
          :prompt
          | :run
          | :swarm
          | :goal
          | :research
          | :research_picker
          | :research_attachment
          | :navigate
          | :help
          | :create_workflow
          | :teamwork
          | :boost

  @type durability :: :interactive | :durable | :none
  @type mode ::
          :single
          | :swarm
          | :research
          | :navigation
          | :help
          | :workflow
          | :teamwork
          | :boost

  @type t :: %__MODULE__{
          kind: kind(),
          objective: String.t() | nil,
          durability: durability(),
          mode: mode(),
          draft?: boolean(),
          boost?: boolean(),
          teamwork?: boolean(),
          blueprint_pattern: String.t() | nil,
          level: String.t() | nil,
          attachment_id: pos_integer() | nil,
          raw_command: String.t() | nil,
          source: String.t()
        }
end

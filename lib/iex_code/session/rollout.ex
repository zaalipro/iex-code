defmodule IexCode.Session.Rollout do
  @moduledoc """
  Append-only JSONL rollout log per session: model turns, tool results,
  pauses, finals, and compaction checkpoints.

  The database stays the source of truth; the rollout file makes any
  session replayable (`replay/1`), rewindable (`rollback/2`), and
  resumable (`resume_messages/2`) without touching the DB, and records
  compaction checkpoints so resumed context matches what the model saw.
  """

  alias IexCode.LLM.ContextCompactor

  @type record :: %{String.t() => term()}

  @doc "Rollout file path for a session under `dir`."
  @spec path_for(String.t(), String.t()) :: String.t()
  def path_for(dir, session_id) when is_binary(dir) and is_binary(session_id) do
    safe = String.replace(session_id, ~r/[^A-Za-z0-9_-]/, "_")
    Path.join([dir, "rollouts", safe <> ".jsonl"])
  end

  @doc "Appends a typed record. Never raises on IO errors."
  @spec record(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def record(path, type, data) when is_binary(path) and is_binary(type) and is_map(data) do
    entry = %{
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "type" => type,
      "data" => data
    }

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, encoded} <- Jason.encode(entry) do
      File.write(path, encoded <> "\n", [:append])
    else
      {:error, reason} -> {:error, {:rollout_write, reason}}
    end
  end

  @doc "Loads records with 1-based `seq` assigned in file order."
  @spec load(String.t()) :: {:ok, [record()]} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.with_index(1)
        |> Enum.reduce_while({:ok, []}, fn {line, seq}, {:ok, acc} ->
          case Jason.decode(line) do
            {:ok, decoded} when is_map(decoded) ->
              {:cont, {:ok, [Map.merge(decoded, %{"seq" => seq}) | acc]}}

            _invalid ->
              {:halt, {:error, {:rollout_corrupt_line, seq}}}
          end
        end)
        |> case do
          {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
          {:error, _reason} = error -> error
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:rollout_read, reason}}
    end
  end

  @doc """
  Replays records into model messages. A `compact` checkpoint replaces all
  earlier messages with its compacted list; `rollback` truncates callers
  via `rollback/2` (replay ignores the marker itself).
  """
  @spec replay([record()]) :: [map()]
  def replay(records) when is_list(records) do
    Enum.reduce(records, [], fn record, messages ->
      case record["type"] do
        "user" ->
          messages ++ [%{role: "user", content: get_in(record, ["data", "content"]) || ""}]

        "assistant" ->
          messages ++
            [
              %{
                role: "assistant",
                content: get_in(record, ["data", "text"]) || "",
                tool_calls: get_in(record, ["data", "tool_calls"]) || []
              }
            ]

        "tool" ->
          messages ++
            [
              %{
                role: "tool",
                tool_call_id: get_in(record, ["data", "tool_call_id"]),
                content: get_in(record, ["data", "content"]) || ""
              }
            ]

        "compact" ->
          case get_in(record, ["data", "messages"]) do
            compacted when is_list(compacted) -> Enum.map(compacted, &atomize_message/1)
            _missing -> messages
          end

        _other ->
          messages
      end
    end)
  end

  defp atomize_message(%{"role" => role} = message) do
    base = %{role: role, content: Map.get(message, "content", "")}

    base =
      if Map.has_key?(message, "tool_calls"),
        do: Map.put(base, :tool_calls, message["tool_calls"]),
        else: base

    if Map.has_key?(message, "tool_call_id"),
      do: Map.put(base, :tool_call_id, message["tool_call_id"]),
      else: base
  end

  defp atomize_message(%{role: _role} = message), do: message
  defp atomize_message(_message), do: %{role: "user", content: ""}

  @doc "Truncates the log after `seq` and appends a rollback marker."
  @spec rollback(String.t(), pos_integer()) :: {:ok, [record()]} | {:error, term()}
  def rollback(path, seq) when is_binary(path) and is_integer(seq) and seq >= 0 do
    with {:ok, records} <- load(path) do
      kept = Enum.filter(records, &(&1["seq"] <= seq))

      lines =
        kept
        |> Enum.map(&Map.delete(&1, "seq"))
        |> Enum.map(&Jason.encode!/1)

      marker =
        Jason.encode!(%{
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "type" => "rollback",
          "data" => %{"to_seq" => seq, "dropped" => length(records) - length(kept)}
        })

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, Enum.join(lines ++ [marker], "\n") <> "\n") do
        load(path)
      else
        {:error, reason} -> {:error, {:rollout_write, reason}}
      end
    end
  end

  @doc "Replays the log, optionally rewound to `seq` first (pure read)."
  @spec resume_messages(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def resume_messages(path, opts \\ []) when is_binary(path) and is_list(opts) do
    with {:ok, records} <- load(path) do
      records =
        case Keyword.get(opts, :to_seq) do
          nil -> records
          seq -> Enum.filter(records, &(&1["seq"] <= seq))
        end

      {:ok, replay(records)}
    end
  end

  @doc """
  Appends a compaction checkpoint when replayed messages exceed the
  compactor threshold. Returns `{:ok, :compacted | :under_threshold}`.
  """
  @spec maybe_compact(String.t(), term(), String.t() | nil) ::
          {:ok, :compacted | :under_threshold} | {:error, term()}
  def maybe_compact(path, settings, model_name \\ nil) when is_binary(path) do
    with {:ok, records} <- load(path) do
      messages = replay(records)
      compacted = ContextCompactor.compact(messages, settings, model_name)

      if compacted == messages do
        {:ok, :under_threshold}
      else
        record(path, "compact", %{
          "messages" => stringify(compacted),
          "dropped" => length(messages) - length(compacted)
        })
        |> case do
          :ok -> {:ok, :compacted}
          {:error, _reason} = error -> error
        end
      end
    end
  end

  defp stringify(value), do: value |> Jason.encode!() |> Jason.decode!()
end

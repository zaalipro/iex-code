defmodule IexCode.Engine.LoopGuard do
  @moduledoc """
  Pure functional tracker for tool-call repetition and doom-loop detection.

  Records `{tool_name, canonical_args_digest, error_boolean, output_digest}`
  per tool invocation and protects `AgentLoop` and `CoderAgent` from burning
  turns on identical failing tool calls:

    * On the 3rd identical failing call (and subsequent warnings below the halt
      ceiling), appends a concise `[HARNESS LOOP GUARD]` guidance suffix to the
      tool's returned message instructing the model to stop repeating the same
      failing arguments and inspect workspace context first.
    * On the 5th consecutive identical failing call, halts cleanly with
      `{:halt, {:agent_doom_loop_detected, tool_name}, guard}` so the caller
      returns `{:error, {:agent_doom_loop_detected, tool_name}}`.
    * Never alters outputs or triggers halts for successful repeated calls.
  """

  @default_warn_threshold 3
  @default_halt_threshold 5
  @max_entries 512

  @ignored_arg_keys MapSet.new([
                      "__workspace_lock_identity__",
                      "__sub_agent__",
                      "__requested_timeout_ms__",
                      "op_id"
                    ])

  @content_read_tools [
    "read_file",
    "view_file",
    "grep_search",
    "ast_search",
    "find_references",
    "lsp_query",
    "semantic_code_search",
    "repo_map",
    "list_dir"
  ]

  @type entry :: {String.t(), String.t(), boolean(), String.t()}

  @type t :: %__MODULE__{
          entries: [entry()],
          failure_counts: %{optional({String.t(), String.t()}) => non_neg_integer()},
          consecutive_failures: non_neg_integer(),
          last_failure_key: {String.t(), String.t()} | nil,
          warn_threshold: pos_integer(),
          halt_threshold: pos_integer()
        }

  defstruct entries: [],
            failure_counts: %{},
            consecutive_failures: 0,
            last_failure_key: nil,
            warn_threshold: @default_warn_threshold,
            halt_threshold: @default_halt_threshold

  @doc """
  Creates a fresh `LoopGuard` tracker.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    warn = Keyword.get(opts, :warn_threshold, @default_warn_threshold)
    halt = Keyword.get(opts, :halt_threshold, @default_halt_threshold)

    %__MODULE__{
      warn_threshold: max(1, warn),
      halt_threshold: max(warn + 1, halt)
    }
  end

  @doc """
  Returns recorded `{tool_name, canonical_args_digest, error_boolean, output_digest}`
  entries in chronological order (oldest first).
  """
  @spec entries(t()) :: [entry()]
  def entries(%__MODULE__{entries: entries}), do: Enum.reverse(entries)

  @doc """
  Computes a deterministic SHA-256 hex digest for tool arguments, invariant to
  map key ordering and atom-vs-string keys while ignoring transient harness keys.
  """
  @spec canonical_args_digest(term()) :: String.t()
  def canonical_args_digest(args) do
    {:v1, canonicalize(args)}
    |> :erlang.term_to_binary()
    |> sha256_hex()
  end

  @doc """
  Computes a SHA-256 hex digest of a raw tool result or formatted output text.
  """
  @spec output_digest(term()) :: String.t()
  def output_digest(output) when is_binary(output), do: sha256_hex(output)

  def output_digest(other) do
    other
    |> inspect(limit: 50, printable_limit: 8_000)
    |> sha256_hex()
  end

  @doc """
  Returns `true` when a raw tool result tuple or formatted output string
  represents a failing tool call.
  """
  @spec failing_result?(term(), String.t() | atom() | nil) :: boolean()
  def failing_result?(result, tool_name \\ nil)
  def failing_result?({:error, _reason}, _tool_name), do: true
  def failing_result?({:ok, output}, tool_name), do: failing_output?(tool_name, output)

  def failing_result?(output, tool_name) when is_binary(output),
    do: failing_output?(tool_name, output)

  def failing_result?(_other, _tool_name), do: false

  @doc """
  Returns `true` when formatted tool output text matches a known harness or tool
  failure signature.
  """
  @spec failing_output?(String.t() | atom() | nil, term()) :: boolean()
  def failing_output?(tool_name \\ nil, output)

  def failing_output?(tool_name, output) when is_binary(output) do
    trimmed = String.trim_leading(output)
    normalized_tool = if is_nil(tool_name), do: nil, else: to_string(tool_name)

    cond do
      String.starts_with?(trimmed, "Tool failed:") ->
        true

      String.starts_with?(trimmed, "ERROR:") ->
        true

      nonzero_leading_exit_code?(trimmed) ->
        true

      normalized_tool in @content_read_tools ->
        false

      nonzero_line_exit_code?(output) ->
        true

      failing_patch_or_edit_message?(output) ->
        true

      true ->
        false
    end
  end

  def failing_output?(_tool_name, _other), do: false

  @doc """
  Records a tool call whose output has already been normalized to text (or is a
  raw `{:ok, text}` / `{:error, reason}` tuple).

  Returns:
    * `{:ok, output_text, updated_guard}` (with `[HARNESS LOOP GUARD]` appended
      on the 3rd+ identical failing call), or
    * `{:halt, {:agent_doom_loop_detected, tool_name}, updated_guard}` on the
      5th consecutive identical failing call.
  """
  @spec record(t(), String.t() | atom(), term(), term()) ::
          {:ok, String.t(), t()}
          | {:halt, {:agent_doom_loop_detected, String.t()}, t()}
  def record(%__MODULE__{} = guard, tool_name, args, {:error, reason} = raw_error) do
    formatted = "Tool failed: " <> format_reason(reason)
    record_formatted(guard, tool_name, args, raw_error, formatted)
  end

  def record(%__MODULE__{} = guard, tool_name, args, {:ok, output} = raw_ok)
      when is_binary(output) do
    record_formatted(guard, tool_name, args, raw_ok, output)
  end

  def record(%__MODULE__{} = guard, tool_name, args, output) when is_binary(output) do
    record_formatted(guard, tool_name, args, output, output)
  end

  def record(%__MODULE__{} = guard, tool_name, args, other) do
    formatted = inspect(other, limit: 50, printable_limit: 4_000)
    record_formatted(guard, tool_name, args, other, formatted)
  end

  @doc """
  Records a tool call given both its raw execution result (`{:ok, _}` /
  `{:error, _}` / binary) and the formatted string that will be returned to the
  model.
  """
  @spec record_formatted(t(), String.t() | atom(), term(), term(), String.t()) ::
          {:ok, String.t(), t()}
          | {:halt, {:agent_doom_loop_detected, String.t()}, t()}
  def record_formatted(%__MODULE__{} = guard, tool_name, args, raw_result, formatted_text)
      when is_binary(formatted_text) do
    name = to_string(tool_name)
    args_digest = canonical_args_digest(args)
    error? = failing_result?(raw_result, name) or failing_output?(name, formatted_text)
    out_digest = output_digest(formatted_text)
    entry = {name, args_digest, error?, out_digest}
    next_entries = Enum.take([entry | guard.entries], @max_entries)
    key = {name, args_digest}

    if not error? do
      next_guard = %__MODULE__{
        guard
        | entries: next_entries,
          failure_counts: Map.delete(guard.failure_counts, key),
          consecutive_failures: 0,
          last_failure_key: nil
      }

      {:ok, formatted_text, next_guard}
    else
      total = Map.get(guard.failure_counts, key, 0) + 1
      consecutive = if guard.last_failure_key == key, do: guard.consecutive_failures + 1, else: 1

      next_guard = %__MODULE__{
        guard
        | entries: next_entries,
          failure_counts: Map.put(guard.failure_counts, key, total),
          consecutive_failures: consecutive,
          last_failure_key: key
      }

      cond do
        consecutive >= guard.halt_threshold ->
          {:halt, {:agent_doom_loop_detected, name}, next_guard}

        total >= guard.warn_threshold or consecutive >= guard.warn_threshold ->
          {:ok, append_guidance(formatted_text, name, max(total, consecutive)), next_guard}

        true ->
          {:ok, formatted_text, next_guard}
      end
    end
  end

  @doc """
  Formats the `[HARNESS LOOP GUARD]` guidance suffix appended on repeated
  identical failing calls.
  """
  @spec guidance_suffix(String.t(), pos_integer()) :: String.t()
  def guidance_suffix(tool_name, failure_count) do
    "[HARNESS LOOP GUARD] Identical failing call to `#{tool_name}` repeated #{failure_count} times " <>
      "with the exact same arguments. Stop repeating these failing arguments—read or search the " <>
      "relevant files/context first and change your approach before retrying."
  end

  defp append_guidance(text, tool_name, failure_count) do
    suffix = guidance_suffix(tool_name, failure_count)

    if String.contains?(text, "[HARNESS LOOP GUARD]") do
      text
    else
      text <> "\n\n" <> suffix
    end
  end

  defp nonzero_leading_exit_code?(trimmed) do
    case Regex.run(~r/\AExit Code:?\s+(-?\d+)(?:\b|:)/, trimmed) do
      [_, code] -> parse_nonzero_int?(code)
      _ -> false
    end
  end

  defp nonzero_line_exit_code?(text) do
    Regex.scan(~r/(?:^|\n)\s*Exit Code:?\s+(-?\d+)(?:\b|:)/, text)
    |> Enum.any?(fn
      [_, code] -> parse_nonzero_int?(code)
      _ -> false
    end)
  end

  defp parse_nonzero_int?(code) do
    case Integer.parse(code) do
      {value, ""} -> value != 0
      _ -> false
    end
  end

  defp failing_patch_or_edit_message?(text) do
    downcased = String.downcase(text)

    String.contains?(downcased, "target content not found") or
      String.contains?(downcased, "multipatch failed") or
      String.contains?(downcased, "ambiguous target") or
      String.contains?(downcased, "ambiguous_target") or
      String.contains?(downcased, "ambiguous_match")
  end

  defp canonicalize(%_{} = struct) do
    {:struct, struct.__struct__, struct |> Map.from_struct() |> canonicalize()}
  end

  defp canonicalize(map) when is_map(map) do
    pairs =
      map
      |> Enum.reduce([], fn {k, v}, acc ->
        key = canonical_key(k)

        if MapSet.member?(@ignored_arg_keys, key) do
          acc
        else
          [{key, canonicalize(v)} | acc]
        end
      end)
      |> Enum.sort_by(&elem(&1, 0))

    {:map, pairs}
  end

  defp canonicalize(list) when is_list(list), do: {:list, Enum.map(list, &canonicalize/1)}

  defp canonicalize(tuple) when is_tuple(tuple),
    do: {:tuple, tuple |> Tuple.to_list() |> Enum.map(&canonicalize/1)}

  defp canonicalize(other), do: other

  defp canonical_key(key) when is_binary(key), do: key
  defp canonical_key(key) when is_atom(key), do: Atom.to_string(key)
  defp canonical_key(key), do: inspect(key)

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason, limit: 20, printable_limit: 4_000)

  defp sha256_hex(binary) when is_binary(binary) do
    :crypto.hash(:sha256, binary)
    |> Base.encode16(case: :lower)
  end
end

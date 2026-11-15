defmodule IexCode.LLM.ContextCompactor do
  @moduledoc """
  Context window compaction and token management engine.

  Monitors conversation token volume against the configured threshold
  (`effective_window_tokens * context_prune_threshold_percent / 100`) and
  executes one of three compaction strategies when exceeded:

    * `"token_compaction"`: Prunes voluminous tool outputs, unified diffs, and stacktraces
      while preserving structural diff headers, exceptions, workspace frames, and exit codes.
    * `"rolling_summary"`: Condenses older conversation turns into a structured summary
      checkpoint with a bounded `Working memory:` coding ledger.
    * `"sliding_window"`: Retains the root objective and latest K turns without splitting
      OpenAI, Anthropic, or Gemini tool exchanges.
  """

  alias IexCode.LLM.Capabilities
  alias IexCode.Settings.AppSettings

  @default_window_tokens 128_000
  @default_threshold_percent 75
  @default_keep_recent_turns 6
  @max_tool_output_chars 1_500
  @max_preserved_middle_lines 20
  @max_preserved_middle_bytes 1_200
  @max_working_memory_files 10
  @max_working_memory_patches 6
  @max_working_memory_failures 6

  @mutation_tools ~w(
    write_file
    edit_file
    patch_file
    apply_patch
    multi_patch
    create_file
    replace_in_file
    git_stage_hunk
    git_unstage_hunk
    git_revert_hunk
    git_commit
  )

  @doc """
  Resolves the effective context window token budget for compaction.

  Supports `:auto` (`context_window_tokens: :auto | "auto"`) and
  `auto_model_window: true` lookup via `IexCode.LLM.Capabilities`, while keeping
  `@default_window_tokens` (`128_000`) whenever `settings` sets an explicit integer
  or omits `:auto`.
  """
  @spec effective_window_tokens(AppSettings.t() | map() | :auto | nil, String.t() | nil) ::
          pos_integer()
  def effective_window_tokens(settings, model_name \\ nil)

  def effective_window_tokens(:auto, model_name),
    do: resolve_auto_window_tokens(%{}, model_name)

  def effective_window_tokens(nil, _model_name), do: @default_window_tokens

  def effective_window_tokens(%AppSettings{} = settings, model_name) do
    auto_flag? = Map.get(settings, :auto_model_window) == true

    cond do
      auto_flag? ->
        resolve_auto_window_tokens(settings, model_name)

      is_integer(settings.context_window_tokens) and settings.context_window_tokens > 0 ->
        settings.context_window_tokens

      true ->
        @default_window_tokens
    end
  end

  def effective_window_tokens(settings, model_name) when is_map(settings) do
    raw_window = raw_setting(settings, :context_window_tokens)
    auto_flag? = raw_setting(settings, :auto_model_window) == true

    cond do
      raw_window in [:auto, "auto"] ->
        resolve_auto_window_tokens(settings, model_name)

      auto_flag? and (is_nil(raw_window) or raw_window == @default_window_tokens) ->
        resolve_auto_window_tokens(settings, model_name)

      is_integer(raw_window) and raw_window > 0 ->
        raw_window

      auto_flag? ->
        resolve_auto_window_tokens(settings, model_name)

      true ->
        @default_window_tokens
    end
  end

  def effective_window_tokens(_other, _model_name), do: @default_window_tokens

  @doc """
  Compacts the message list if estimated tokens exceed the configured threshold.
  """
  @spec compact(list(map()), AppSettings.t() | map() | nil, String.t() | nil) :: list(map())
  def compact(messages, settings, model_name \\ nil)
  def compact([], _settings, _model_name), do: []

  def compact(messages, settings, model_name) when is_list(messages) do
    window_tokens = effective_window_tokens(settings, model_name)

    threshold_percent =
      get_setting(settings, :context_prune_threshold_percent, @default_threshold_percent)

    strategy = get_setting(settings, :context_compaction_strategy, "token_compaction")
    keep_turns = get_setting(settings, :keep_recent_turns, @default_keep_recent_turns)

    trigger_tokens = trunc(window_tokens * (threshold_percent / 100))
    current_tokens = estimate_tokens(messages)

    if current_tokens > trigger_tokens do
      apply_strategy(strategy, messages, trigger_tokens, keep_turns, model_name)
    else
      messages
    end
  end

  @doc """
  Fits an actual adapter payload, removing oldest complete protocol groups.
  Keeps the latest objective, all required instruction messages,
  explicitly mandatory messages, and steering. Never expands a boundary after
  the final fit check. Ordinary fitting requests are returned unchanged.
  """
  def compact_request(messages, settings, builder, fits?) do
    body = builder.(messages)

    if fits?.(body) do
      {:ok, messages, body}
    else
      users =
        messages
        |> Enum.with_index()
        |> Enum.filter(fn {m, _} ->
          role(m) == "user" and not steering?(m) and not tool_reply_message?(m)
        end)
        |> Enum.map(&elem(&1, 1))

      objectives =
        messages
        |> Enum.with_index()
        |> Enum.filter(fn {msg, _} -> get_message_field(msg, :budget_objective) == true end)
        |> Enum.map(&elem(&1, 1))

      protected =
        if objectives == [], do: Enum.reject([List.last(users)], &is_nil/1), else: objectives

      groups = request_groups(Enum.with_index(messages))

      groups =
        if get_setting(settings, :context_compaction_strategy, "token_compaction") ==
             "token_compaction" do
          Enum.map(groups, fn group ->
            if Enum.any?(group, fn {msg, index} -> mandatory?(msg, index, protected) end) do
              group
            else
              Enum.map(group, fn {msg, index} -> {compact_tool_message(msg), index} end)
            end
          end)
        else
          groups
        end

      fit_groups(
        groups,
        protected,
        builder,
        fits?,
        get_setting(settings, :context_compaction_strategy, "token_compaction"),
        []
      )
    end
  end

  defp fit_groups(groups, protected, builder, fits?, strategy, dropped) do
    messages = for group <- groups, {msg, _} <- group, do: msg
    body = builder.(messages)

    if fits?.(body) do
      if strategy == "rolling_summary" and dropped != [] do
        inject_fitting_request_summary(messages, groups, dropped, builder, fits?, body)
      else
        {:ok, messages, body}
      end
    else
      removable =
        Enum.find_index(groups, fn group ->
          not Enum.any?(group, fn {msg, index} -> mandatory?(msg, index, protected) end)
        end)

      if is_nil(removable),
        do: {:error, body},
        else:
          fit_groups(
            List.delete_at(groups, removable),
            protected,
            builder,
            fits?,
            strategy,
            dropped ++ Enum.map(Enum.at(groups, removable), &elem(&1, 0))
          )
    end
  end

  defp inject_fitting_request_summary(messages, groups, dropped, builder, fits?, fallback_body) do
    turn_lines = build_summary_lines(dropped)
    wm_lines = build_working_memory_lines(dropped)
    full_lines = turn_lines ++ wm_lines

    # Insert after a complete group, never between tool requests/replies.
    {head, tail} = Enum.split(messages, length(List.first(groups) || []))

    candidates =
      [
        full_lines,
        build_bounded_summary_lines(turn_lines, wm_lines, 240),
        build_bounded_summary_lines(turn_lines, wm_lines, 80),
        build_bounded_summary_lines(turn_lines, wm_lines, 32)
      ]
      |> Enum.reject(&(&1 == []))
      |> Enum.uniq()

    found =
      Enum.find_value(candidates, fn lines ->
        summary = %{
          role: "user",
          content: "Summary of earlier conversation history:\n" <> Enum.join(lines, "\n")
        }

        summarized = head ++ [summary] ++ tail
        summary_body = builder.(summarized)
        if fits?.(summary_body), do: {:ok, summarized, summary_body}
      end)

    found || {:ok, messages, fallback_body}
  end

  defp request_groups([]), do: []

  defp request_groups([{msg, _} = entry | rest]) do
    if tool_request_message?(msg) do
      {replies, tail} = Enum.split_while(rest, fn {m, _} -> tool_reply_message?(m) end)
      [[entry | replies] | request_groups(tail)]
    else
      [[entry] | request_groups(rest)]
    end
  end

  defp mandatory?(msg, index, protected) do
    index in protected or role(msg) in ["system", "developer"] or
      get_message_field(msg, :budget_mandatory) == true or steering?(msg)
  end

  defp steering?(msg) do
    case get_message_field(msg, :content) do
      text when is_binary(text) -> String.starts_with?(text, "Steering guidance:")
      _ -> false
    end
  end

  defp role(msg), do: to_string(get_message_field(msg, :role) || "")

  @doc """
  Estimates the token count for a list of messages or a single message/string.
  Roughly 1 token ≈ 4 bytes of text plus per-message overhead.
  """
  @spec estimate_tokens(list(map()) | map() | String.t()) :: integer()
  def estimate_tokens(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      acc + estimate_message_tokens(msg) + 4
    end)
  end

  def estimate_tokens(msg) when is_map(msg) do
    estimate_message_tokens(msg)
  end

  def estimate_tokens(text) when is_binary(text) do
    div(byte_size(text), 4) + 1
  end

  def estimate_tokens(_), do: 0

  @doc """
  Expands a kept message suffix back across a cut tool exchange.

  A tool request and all of its replies are one protocol exchange across OpenAI
  (`tool_calls` + `role: "tool"`), Anthropic (`tool_use` + `role: "user"`
  `tool_result` blocks), and Gemini (`functionCall` + `functionResponse` parts).
  When a budget cut lands between them, the leading tool replies are orphaned from
  their assistant request. Given the dropped prefix and the kept suffix, moves
  messages back from dropped to kept until the kept window no longer starts
  mid-exchange.
  """
  @spec restore_exchange_boundary(list(map()), list(map())) :: list(map())
  def restore_exchange_boundary(dropped, kept) when is_list(dropped) and is_list(kept) do
    {_remaining, expanded} = restore_tool_request(Enum.reverse(dropped), kept)
    expanded
  end

  defp estimate_message_tokens(msg) when is_map(msg) do
    content = get_message_field(msg, :content)
    parts = get_message_field(msg, :parts)
    msg_role = get_message_field(msg, :role) || ""
    tool_calls = get_message_field(msg, :tool_calls)

    content_tokens =
      cond do
        is_binary(content) -> div(byte_size(content), 4) + 1
        is_list(content) -> div(byte_size(inspect(content)), 4) + 1
        is_nil(content) and is_list(parts) -> 0
        true -> 1
      end

    parts_tokens =
      if is_list(parts) do
        div(byte_size(inspect(parts)), 4) + 1
      else
        0
      end

    tool_tokens =
      if is_list(tool_calls) do
        div(byte_size(inspect(tool_calls)), 4) + 2
      else
        0
      end

    role_tokens = div(byte_size(to_string(msg_role)), 4) + 1
    content_tokens + parts_tokens + tool_tokens + role_tokens
  end

  defp estimate_message_tokens(_), do: 0

  defp apply_strategy("token_compaction", messages, target_tokens, keep_turns, model_name) do
    compacted = Enum.map(messages, &compact_tool_message/1)

    if estimate_tokens(compacted) > target_tokens do
      apply_strategy("sliding_window", compacted, target_tokens, keep_turns, model_name)
    else
      compacted
    end
  end

  defp apply_strategy("sliding_window", messages, _target_tokens, keep_turns, _model_name) do
    case messages do
      [root | rest] when length(rest) > keep_turns ->
        {_older, recent} = split_recent(rest, keep_turns)
        [root | recent]

      _other ->
        messages
    end
  end

  defp apply_strategy("rolling_summary", messages, target_tokens, keep_turns, model_name) do
    case messages do
      [root | rest] when length(rest) > keep_turns ->
        {older, recent} = split_recent(rest, keep_turns)

        if older == [] do
          [root | recent]
        else
          turn_lines = build_summary_lines(older)
          wm_lines = build_working_memory_lines(older)
          all_lines = turn_lines ++ wm_lines

          header_text = "Summary of earlier conversation history:\n"
          empty_summary_msg = make_summary_message(root, header_text)
          base_tokens = estimate_tokens([root, empty_summary_msg | recent])

          available_tokens = target_tokens - base_tokens

          pruned_lines =
            cond do
              available_tokens > 0 ->
                build_bounded_summary_lines(turn_lines, wm_lines, available_tokens)

              length(older) <= keep_turns * 2 ->
                all_lines

              true ->
                []
            end

          if pruned_lines == [] and available_tokens <= 0 and length(older) > keep_turns * 2 do
            apply_strategy("sliding_window", messages, target_tokens, keep_turns, model_name)
          else
            summary_text = Enum.join(pruned_lines, "\n")
            summary_msg = make_summary_message(root, header_text <> summary_text)
            compacted = [root, summary_msg | recent]

            if estimate_tokens(compacted) > target_tokens and length(older) > keep_turns * 2 do
              apply_strategy("sliding_window", messages, target_tokens, keep_turns, model_name)
            else
              compacted
            end
          end
        end

      _other ->
        messages
    end
  end

  defp apply_strategy(_unknown_strategy, messages, target_tokens, keep_turns, model_name) do
    apply_strategy("token_compaction", messages, target_tokens, keep_turns, model_name)
  end

  defp make_summary_message(root, content) do
    if atom_keyed?(root) do
      %{role: "system", content: content}
    else
      %{"role" => "system", "content" => content}
    end
  end

  # A tool request and all of its replies are one protocol exchange. Expand a
  # cut through the replies back to the assistant request, even when that means
  # keeping more than the preferred number of recent messages.
  defp split_recent(messages, keep_turns) do
    {older, recent} = Enum.split(messages, max(length(messages) - keep_turns, 0))
    restore_tool_request(Enum.reverse(older), recent)
  end

  defp restore_tool_request([previous | older] = reversed_older, [first | _] = recent) do
    if tool_reply_message?(first) and restorable_exchange?(reversed_older, first) do
      restore_tool_request(older, [previous | recent])
    else
      {Enum.reverse(reversed_older), recent}
    end
  end

  defp restore_tool_request(reversed_older, recent), do: {Enum.reverse(reversed_older), recent}

  defp restorable_exchange?(reversed_older, first) do
    remaining = Enum.drop_while(reversed_older, &tool_reply_message?/1)

    case remaining do
      [candidate | _] ->
        tool_request_message?(candidate) or
          (role(candidate) in ["assistant", "model"] and role(first) in ["tool", "function"])

      [] ->
        false
    end
  end

  defp tool_request_message?(msg) when is_map(msg) do
    role(msg) in ["assistant", "model"] and
      (non_empty_list?(get_message_field(msg, :tool_calls)) or
         contains_tool_request_block?(get_message_field(msg, :content)) or
         contains_tool_request_block?(get_message_field(msg, :parts)))
  end

  defp tool_request_message?(_), do: false

  defp tool_reply_message?(msg) when is_map(msg) do
    msg_role = role(msg)

    msg_role in ["tool", "function"] or
      (msg_role == "user" and
         (contains_tool_reply_block?(get_message_field(msg, :content)) or
            contains_tool_reply_block?(get_message_field(msg, :parts))))
  end

  defp tool_reply_message?(_), do: false

  defp contains_tool_request_block?(blocks) when is_list(blocks) do
    Enum.any?(blocks, fn
      block when is_map(block) ->
        block_type(block) in ["tool_use", "functionCall", "function_call"] or
          has_map_field?(block, :functionCall) or
          has_map_field?(block, :function_call)

      _ ->
        false
    end)
  end

  defp contains_tool_request_block?(_), do: false

  defp contains_tool_reply_block?(blocks) when is_list(blocks) do
    Enum.any?(blocks, fn
      block when is_map(block) ->
        block_type(block) in ["tool_result", "functionResponse", "function_response"] or
          has_map_field?(block, :functionResponse) or
          has_map_field?(block, :function_response)

      _ ->
        false
    end)
  end

  defp contains_tool_reply_block?(_), do: false

  defp block_type(block) when is_map(block) do
    case Map.get(block, :type) || Map.get(block, "type") do
      nil -> ""
      val -> to_string(val)
    end
  end

  defp has_map_field?(map, field) when is_map(map) and is_atom(field) do
    Map.has_key?(map, field) or Map.has_key?(map, Atom.to_string(field))
  end

  defp non_empty_list?([_ | _]), do: true
  defp non_empty_list?(_), do: false

  @doc """
  Compacts a single message if it contains bulky tool outputs.
  """
  def compact_tool_message(msg) when is_map(msg) do
    msg_role = to_string(get_message_field(msg, :role) || "")
    content = get_message_field(msg, :content)
    parts = get_message_field(msg, :parts)

    cond do
      (msg_role in ["tool", "function", "system"] or tool_result_content?(content)) and
        is_binary(content) and byte_size(content) > @max_tool_output_chars ->
        put_message_field(msg, :content, prune_bulky_content(content))

      is_list(content) and contains_tool_reply_block?(content) ->
        put_message_field(msg, :content, Enum.map(content, &compact_reply_block/1))

      is_list(parts) and contains_tool_reply_block?(parts) ->
        put_message_field(msg, :parts, Enum.map(parts, &compact_reply_block/1))

      true ->
        msg
    end
  end

  def compact_tool_message(msg), do: msg

  defp compact_reply_block(block) when is_map(block) do
    cond do
      block_type(block) == "tool_result" ->
        case get_message_field(block, :content) do
          text when is_binary(text) and byte_size(text) > @max_tool_output_chars ->
            put_message_field(block, :content, prune_bulky_content(text))

          nested when is_list(nested) ->
            compacted_nested =
              Enum.map(nested, fn
                item when is_map(item) ->
                  case get_message_field(item, :text) do
                    t when is_binary(t) and byte_size(t) > @max_tool_output_chars ->
                      put_message_field(item, :text, prune_bulky_content(t))

                    _ ->
                      item
                  end

                other ->
                  other
              end)

            put_message_field(block, :content, compacted_nested)

          _ ->
            block
        end

      has_map_field?(block, :functionResponse) ->
        compact_function_response_field(block, :functionResponse)

      has_map_field?(block, :function_response) ->
        compact_function_response_field(block, :function_response)

      true ->
        block
    end
  end

  defp compact_reply_block(other), do: other

  defp compact_function_response_field(block, key) do
    fr = get_message_field(block, key)

    if is_map(fr) do
      resp = get_message_field(fr, :response)

      cond do
        is_binary(resp) and byte_size(resp) > @max_tool_output_chars ->
          put_message_field(
            block,
            key,
            put_message_field(fr, :response, prune_bulky_content(resp))
          )

        is_map(resp) ->
          compacted_resp =
            Map.new(resp, fn {rk, rv} ->
              if is_binary(rv) and byte_size(rv) > @max_tool_output_chars do
                {rk, prune_bulky_content(rv)}
              else
                {rk, rv}
              end
            end)

          put_message_field(block, key, put_message_field(fr, :response, compacted_resp))

        true ->
          block
      end
    else
      block
    end
  end

  defp tool_result_content?(content) when is_binary(content) do
    String.contains?(content, "Exit Code") or
      String.contains?(content, "matches found") or
      String.contains?(content, "Showing lines") or
      String.contains?(content, "diff --git")
  end

  defp tool_result_content?(_), do: false

  @doc false
  def prune_bulky_content(content) when is_binary(content) do
    lines = String.split(content, ~r/\r?\n/)
    total_lines = length(lines)

    exit_code_line = Enum.find(lines, &String.starts_with?(&1, "Exit Code"))

    if total_lines <= 16 do
      compact_few_lines(content, lines, total_lines, exit_code_line)
    else
      compact_many_lines(content, lines, total_lines, exit_code_line)
    end
  end

  defp compact_few_lines(content, lines, _total_lines, exit_code_line) do
    total_bytes = byte_size(content)
    head_bytes = 600
    tail_bytes = 300

    head = utf8_slice_prefix(content, head_bytes)
    tail = utf8_slice_suffix(content, tail_bytes)

    preserved_salient =
      lines
      |> Enum.filter(&salient_diagnostic_line?/1)
      |> Enum.map(&truncate_line(&1, 180))
      |> Enum.reject(&(String.contains?(head, &1) or String.contains?(tail, &1)))
      |> Enum.uniq()
      |> take_lines_within_bytes(4, 360)

    salient_section =
      if preserved_salient == [] do
        nil
      else
        Enum.join(preserved_salient, "\n") <> "\n"
      end

    kept_bytes =
      byte_size(head) + byte_size(tail) +
        if(salient_section, do: byte_size(salient_section), else: 0)

    compacted_bytes = max(0, total_bytes - kept_bytes)

    prepend_exit_code =
      if exit_code_line && not String.contains?(head, exit_code_line) do
        exit_code_line <> "\n"
      end

    banner = "\n... [compacted #{compacted_bytes} bytes of verbose tool output] ...\n"

    [prepend_exit_code, head, banner, salient_section, tail]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end

  defp compact_many_lines(content, lines, total_lines, exit_code_line) do
    header_lines = Enum.take(lines, 12)
    footer_lines = Enum.take(lines, -4)
    middle_lines = lines |> Enum.drop(12) |> Enum.drop(-4)

    preserved_middle = select_salient_middle_lines(middle_lines, exit_code_line)
    omitted_lines = max(0, total_lines - 16 - length(preserved_middle))

    if omitted_lines == 0 do
      compact_few_lines(content, lines, total_lines, exit_code_line)
    else
      header_lines = Enum.map(header_lines, &truncate_line(&1, 240))
      footer_lines = Enum.map(footer_lines, &truncate_line(&1, 240))

      prepend_exit_code =
        if exit_code_line && not Enum.any?(header_lines, &String.starts_with?(&1, exit_code_line)) do
          exit_code_line <> "\n"
        end

      middle_section =
        if preserved_middle == [] do
          "\n... [compacted #{omitted_lines} lines of verbose tool output] ...\n"
        else
          "\n" <>
            Enum.join(preserved_middle, "\n") <>
            "\n... [compacted #{omitted_lines} lines of verbose tool output] ...\n"
        end

      [
        prepend_exit_code,
        Enum.join(header_lines, "\n"),
        middle_section,
        Enum.join(footer_lines, "\n")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("")
    end
  end

  defp select_salient_middle_lines(middle_lines, exit_code_line) do
    indexed_candidates =
      middle_lines
      |> Enum.with_index()
      |> Enum.reduce({[], nil}, fn {line, idx}, {acc, prev_hunk} ->
        priority = salient_line_priority(line)

        cond do
          is_nil(priority) ->
            {acc, prev_hunk}

          exit_code_line != nil and line == exit_code_line ->
            {acc, prev_hunk}

          priority == 2 and line == prev_hunk ->
            # Deduplicate identical repeated hunk headers in synthetic bulky diffs
            {acc, prev_hunk}

          true ->
            formatted = truncate_line(line, 200)
            next_hunk = if priority == 2, do: line, else: prev_hunk
            {[{idx, priority, formatted} | acc], next_hunk}
        end
      end)
      |> elem(0)
      |> Enum.reverse()

    if indexed_candidates == [] do
      []
    else
      # Select highest-priority structural headers and failure frames first,
      # then restore original transcript line order.
      indexed_candidates
      |> Enum.sort_by(fn {idx, priority, _text} -> {priority, idx} end)
      |> take_indexed_within_budget(@max_preserved_middle_lines, @max_preserved_middle_bytes)
      |> Enum.sort_by(fn {idx, _priority, _text} -> idx end)
      |> Enum.map(&elem(&1, 2))
    end
  end

  # Priority 1: file-level diff headers, Elixir exceptions, compiler errors, workspace stack frames
  # Priority 2: hunk headers (@@ ... @@) and ExUnit failure titles
  defp salient_line_priority(line) when is_binary(line) do
    trimmed = String.trim_leading(line)

    cond do
      String.starts_with?(line, "diff --git ") ->
        1

      String.starts_with?(line, "--- ") or String.starts_with?(line, "+++ ") ->
        1

      String.starts_with?(trimmed, "** (") ->
        1

      Regex.match?(~r/(?:^|[\s(])(?:lib|test)\/[A-Za-z0-9_\/.\-]+\.exs?:\d+\b/, line) ->
        1

      Regex.match?(~r/^error:\s+\S+/, trimmed) ->
        1

      String.starts_with?(line, "@@ ") ->
        2

      Regex.match?(~r/^\d+\)\s+test\s+/, trimmed) ->
        2

      true ->
        nil
    end
  end

  defp salient_diagnostic_line?(line), do: not is_nil(salient_line_priority(line))

  defp take_indexed_within_budget(items, max_count, max_bytes) do
    items
    |> Enum.reduce_while({[], 0, 0}, fn {_idx, _prio, text} = item, {acc, count, bytes} ->
      next_bytes = bytes + byte_size(text) + 1

      if count < max_count and next_bytes <= max_bytes do
        {:cont, {[item | acc], count + 1, next_bytes}}
      else
        {:halt, {acc, count, bytes}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp take_lines_within_bytes(lines, max_count, max_bytes) do
    lines
    |> Enum.reduce_while({[], 0, 0}, fn line, {acc, count, bytes} ->
      next_bytes = bytes + byte_size(line) + 1

      if count < max_count and next_bytes <= max_bytes do
        {:cont, {[line | acc], count + 1, next_bytes}}
      else
        {:halt, {acc, count, bytes}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp truncate_line(line, max_bytes) when byte_size(line) <= max_bytes, do: line

  defp truncate_line(line, max_bytes) do
    utf8_slice_prefix(line, max(max_bytes - 3, 1)) <> "..."
  end

  defp build_summary_lines(messages) do
    Enum.map(messages, fn msg ->
      msg_role =
        if tool_reply_message?(msg) do
          "tool"
        else
          to_string(get_message_field(msg, :role) || "unknown")
        end

      content = extract_message_text(msg)
      first_line = content |> String.split("\n") |> List.first() || ""
      snippet = String.slice(first_line, 0, 120)

      case msg_role do
        "user" -> "- User requested: #{snippet}"
        "assistant" -> "- Assistant planned: #{snippet}"
        "model" -> "- Assistant planned: #{snippet}"
        "tool" -> "- Tool executed: #{snippet}"
        "function" -> "- Tool executed: #{snippet}"
        _ -> "- #{msg_role}: #{snippet}"
      end
    end)
  end

  # --- Structured Coding Working-Memory Ledger ---

  defp build_working_memory_lines(messages) when is_list(messages) do
    ledger = extract_working_memory(messages)

    bullets =
      [
        format_ledger_bullet("Files", ledger.files),
        format_ledger_bullet("Patches/Commits", ledger.patches),
        format_ledger_bullet("Failures", ledger.failures)
      ]
      |> Enum.reject(&is_nil/1)

    if bullets == [] do
      []
    else
      ["Working memory:" | bullets]
    end
  end

  defp format_ledger_bullet(_label, []), do: nil
  defp format_ledger_bullet(label, items), do: "- #{label}: #{Enum.join(items, "; ")}"

  defp extract_working_memory(messages) do
    acc = %{
      files_rev: [],
      patches_rev: [],
      failure_locs_rev: [],
      exceptions_rev: [],
      nonzero_exits_rev: [],
      latest_exit: nil
    }

    final =
      Enum.reduce(messages, acc, fn msg, st ->
        st
        |> collect_from_tool_invocations(msg)
        |> collect_from_message_text(extract_all_message_texts(msg))
      end)

    files =
      final.files_rev
      |> uniq_most_recent(@max_working_memory_files)

    patches =
      final.patches_rev
      |> uniq_most_recent(@max_working_memory_patches)

    failures = assemble_failure_entries(final)

    %{
      files: files,
      patches: patches,
      failures: failures
    }
  end

  defp assemble_failure_entries(final) do
    recent_exits = uniq_most_recent(final.nonzero_exits_rev, 2)
    recent_exceptions = uniq_most_recent(final.exceptions_rev, 2)
    recent_locs = uniq_most_recent(final.failure_locs_rev, @max_working_memory_failures)

    has_failure? = recent_exits != [] or recent_exceptions != [] or recent_locs != []

    if not has_failure? do
      []
    else
      exit_items =
        cond do
          recent_exits != [] and not is_nil(final.latest_exit) and
              final.latest_exit not in recent_exits ->
            recent_exits ++ ["latest #{final.latest_exit}"]

          recent_exits != [] ->
            recent_exits

          not is_nil(final.latest_exit) ->
            [final.latest_exit]

          true ->
            []
        end

      (exit_items ++ recent_exceptions ++ recent_locs)
      |> Enum.take(@max_working_memory_failures)
    end
  end

  defp uniq_most_recent(items_rev, limit) do
    items_rev
    |> Enum.reduce({[], MapSet.new(), 0}, fn item, {acc, seen, count} ->
      cond do
        count >= limit -> {acc, seen, count}
        MapSet.member?(seen, item) -> {acc, seen, count}
        true -> {[item | acc], MapSet.put(seen, item), count + 1}
      end
    end)
    |> elem(0)
  end

  defp collect_from_tool_invocations(st, msg) when is_map(msg) do
    invocations = extract_tool_invocations(msg)

    Enum.reduce(invocations, st, fn {tool_name, args}, acc ->
      arg_paths = extract_paths_from_args(args)
      acc = Enum.reduce(arg_paths, acc, &record_workspace_path(&2, &1))

      cond do
        tool_name in @mutation_tools and arg_paths != [] ->
          Enum.reduce(arg_paths, acc, fn path, inner ->
            %{inner | patches_rev: ["patched #{path}" | inner.patches_rev]}
          end)

        tool_name == "git_commit" ->
          commit_msg =
            (is_map(args) && (Map.get(args, "message") || Map.get(args, :message))) || "commit"

          short_msg = truncate_line(to_string(commit_msg), 60)
          %{acc | patches_rev: ["git commit (#{short_msg})" | acc.patches_rev]}

        true ->
          acc
      end
    end)
  end

  defp collect_from_tool_invocations(st, _), do: st

  defp extract_tool_invocations(msg) do
    canonical =
      msg
      |> get_message_field(:tool_calls)
      |> List.wrap()
      |> Enum.flat_map(fn
        tc when is_map(tc) ->
          fn_map = get_message_field(tc, :function)

          name =
            get_message_field(tc, :name) ||
              (is_map(fn_map) && get_message_field(fn_map, :name))

          raw_args =
            get_message_field(tc, :args) ||
              get_message_field(tc, :arguments) ||
              (is_map(fn_map) && get_message_field(fn_map, :arguments))

          if is_binary(name), do: [{name, decode_tool_args(raw_args)}], else: []

        _ ->
          []
      end)

    blocks =
      (list_or_empty(get_message_field(msg, :content)) ++
         list_or_empty(get_message_field(msg, :parts)))
      |> Enum.flat_map(fn
        block when is_map(block) ->
          cond do
            block_type(block) == "tool_use" ->
              name = get_message_field(block, :name)
              input = get_message_field(block, :input)
              if is_binary(name), do: [{name, decode_tool_args(input)}], else: []

            has_map_field?(block, :functionCall) or has_map_field?(block, :function_call) ->
              fc =
                get_message_field(block, :functionCall) ||
                  get_message_field(block, :function_call)

              if is_map(fc) do
                name = get_message_field(fc, :name)
                args = get_message_field(fc, :args)
                if is_binary(name), do: [{name, decode_tool_args(args)}], else: []
              else
                []
              end

            true ->
              []
          end

        _ ->
          []
      end)

    canonical ++ blocks
  end

  defp decode_tool_args(args) when is_map(args), do: args

  defp decode_tool_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_tool_args(_), do: %{}

  defp extract_paths_from_args(args) when is_map(args) do
    direct_keys = ~w(path file_path target_file file destination source_path target_path)

    direct =
      Enum.flat_map(direct_keys, fn key ->
        case Map.get(args, key) || fetch_known_atom_key(args, key) do
          val when is_binary(val) -> [val]
          _ -> []
        end
      end)

    list_keys = ~w(paths files changed_files active_paths)

    from_lists =
      Enum.flat_map(list_keys, fn key ->
        case Map.get(args, key) || fetch_known_atom_key(args, key) do
          vals when is_list(vals) -> Enum.filter(vals, &is_binary/1)
          _ -> []
        end
      end)

    from_patches =
      case Map.get(args, "patches") || Map.get(args, :patches) do
        patches when is_list(patches) ->
          Enum.flat_map(patches, fn
            p when is_map(p) ->
              case Map.get(p, "path") || Map.get(p, :path) || Map.get(p, "file") ||
                     Map.get(p, :file) do
                val when is_binary(val) -> [val]
                _ -> []
              end

            _ ->
              []
          end)

        _ ->
          []
      end

    direct ++ from_lists ++ from_patches
  end

  defp extract_paths_from_args(_), do: []

  defp fetch_known_atom_key(map, "path"), do: Map.get(map, :path)
  defp fetch_known_atom_key(map, "file_path"), do: Map.get(map, :file_path)
  defp fetch_known_atom_key(map, "target_file"), do: Map.get(map, :target_file)
  defp fetch_known_atom_key(map, "file"), do: Map.get(map, :file)
  defp fetch_known_atom_key(map, "destination"), do: Map.get(map, :destination)
  defp fetch_known_atom_key(map, "source_path"), do: Map.get(map, :source_path)
  defp fetch_known_atom_key(map, "target_path"), do: Map.get(map, :target_path)
  defp fetch_known_atom_key(map, "paths"), do: Map.get(map, :paths)
  defp fetch_known_atom_key(map, "files"), do: Map.get(map, :files)
  defp fetch_known_atom_key(map, "changed_files"), do: Map.get(map, :changed_files)
  defp fetch_known_atom_key(map, "active_paths"), do: Map.get(map, :active_paths)
  defp fetch_known_atom_key(_map, _other), do: nil

  defp collect_from_message_text(st, texts) when is_list(texts) do
    Enum.reduce(texts, st, &scan_text_for_ledger(&2, &1))
  end

  defp scan_text_for_ledger(st, text) when is_binary(text) and text != "" do
    # Bound per-message regex scan size so pathological multi-MB blobs stay O(1)
    sample =
      if byte_size(text) > 24_000 do
        utf8_slice_prefix(text, 16_000) <> "\n" <> utf8_slice_suffix(text, 8_000)
      else
        text
      end

    st
    |> scan_diff_patches(sample)
    |> scan_git_commits(sample)
    |> scan_exit_codes(sample)
    |> scan_failures_and_locations(sample)
    |> scan_referenced_files(sample)
  end

  defp scan_text_for_ledger(st, _), do: st

  defp scan_diff_patches(st, sample) do
    Regex.scan(~r/^diff --git a\/(\S+)\s+b\/(\S+)/m, sample)
    |> Enum.reduce(st, fn
      [_, a_path, b_path], acc ->
        case normalize_repo_path(b_path) || normalize_repo_path(a_path) do
          nil ->
            acc

          clean ->
            acc = %{acc | files_rev: [clean | acc.files_rev]}
            %{acc | patches_rev: ["diff #{clean}" | acc.patches_rev]}
        end

      _, acc ->
        acc
    end)
  end

  defp scan_git_commits(st, sample) do
    bracket_commits =
      Regex.scan(~r/\[[\w\/.\-]+\s+([0-9a-f]{7,40})\]\s+([^\r\n]+)/, sample)
      |> Enum.map(fn [_, sha, subject] ->
        "commit #{String.slice(sha, 0, 7)} (#{truncate_line(String.trim(subject), 48)})"
      end)

    explicit_commits =
      Regex.scan(~r/^commit\s+([0-9a-f]{7,40})\b/mi, sample)
      |> Enum.map(fn [_, sha] -> "commit #{String.slice(sha, 0, 7)}" end)

    applied_notices =
      Regex.scan(
        ~r/(?:Applied patch|Patched|Updated|Wrote)\s+(?:to\s+)?([A-Za-z0-9_.\-]+(?:\/[A-Za-z0-9_.\-]+)+\.[A-Za-z0-9]+)/,
        sample
      )
      |> Enum.flat_map(fn [_, path] ->
        case normalize_repo_path(path) do
          nil -> []
          clean -> ["patched #{clean}"]
        end
      end)

    Enum.reduce(bracket_commits ++ explicit_commits ++ applied_notices, st, fn item, acc ->
      %{acc | patches_rev: [item | acc.patches_rev]}
    end)
  end

  defp scan_exit_codes(st, sample) do
    Regex.scan(~r/(?:Exit Code:?|exited with code|exit status:?)\s*(\d+)/i, sample)
    |> Enum.reduce(st, fn [_, code_str], acc ->
      label = "Exit Code #{code_str}"

      if code_str == "0" do
        %{acc | latest_exit: label}
      else
        %{acc | latest_exit: label, nonzero_exits_rev: [label | acc.nonzero_exits_rev]}
      end
    end)
  end

  defp scan_failures_and_locations(st, sample) do
    exceptions =
      Regex.scan(~r/\*\*\s*\([A-Za-z0-9_.]+\)\s*[^\r\n]+/, sample)
      |> Enum.map(fn [line] -> truncate_line(String.trim(line), 96) end)

    compiler_errors =
      Regex.scan(~r/^error:\s+[^\r\n]+/m, sample)
      |> Enum.map(fn [line] -> truncate_line(String.trim(line), 96) end)

    # Extract file:line references when failure context exists or from test/lib stacktraces
    has_error_signal? =
      exceptions != [] or compiler_errors != [] or
        st.nonzero_exits_rev != [] or
        Regex.match?(~r/(?:\d+\s+failures?\b|Assertion with|CompileError|stacktrace:)/, sample)

    loc_matches =
      Regex.scan(
        ~r/(?:^|[\s(])((?:lib|test|config|priv|eval)\/[A-Za-z0-9_\/.\-]+\.exs?):(\d+)\b/m,
        sample
      )

    st =
      Enum.reduce(loc_matches, st, fn [_, path, line_no], acc ->
        acc = record_workspace_path(acc, path)

        if has_error_signal? do
          %{acc | failure_locs_rev: ["#{path}:#{line_no}" | acc.failure_locs_rev]}
        else
          acc
        end
      end)

    Enum.reduce(exceptions ++ compiler_errors, st, fn exc, acc ->
      %{acc | exceptions_rev: [exc | acc.exceptions_rev]}
    end)
  end

  defp scan_referenced_files(st, sample) do
    Regex.scan(
      ~r/(?:^|[\s`"'(])((?:lib|test|config|priv|assets|eval|rel|\.iexcode)\/[A-Za-z0-9_\/.\-]+\.[A-Za-z0-9]+|mix\.exs|AGENTS\.md|CLAUDE\.md|CODEX\.md)\b/m,
      sample
    )
    |> Enum.reduce(st, fn
      [_, path], acc -> record_workspace_path(acc, path)
      _, acc -> acc
    end)
  end

  defp record_workspace_path(st, raw_path) when is_binary(raw_path) do
    case normalize_repo_path(raw_path) do
      nil -> st
      clean -> %{st | files_rev: [clean | st.files_rev]}
    end
  end

  defp record_workspace_path(st, _), do: st

  defp normalize_repo_path(raw_path) when is_binary(raw_path) do
    cleaned =
      raw_path
      |> String.trim()
      |> String.replace(~r/:\d+(?::\d+)?$/, "")
      |> String.replace_prefix("./", "")

    cleaned =
      cond do
        String.starts_with?(cleaned, "a/") and String.contains?(cleaned, "/") ->
          maybe_rest = String.replace_prefix(cleaned, "a/", "")
          if workspace_like_subpath?(maybe_rest), do: maybe_rest, else: cleaned

        String.starts_with?(cleaned, "b/") and String.contains?(cleaned, "/") ->
          maybe_rest = String.replace_prefix(cleaned, "b/", "")
          if workspace_like_subpath?(maybe_rest), do: maybe_rest, else: cleaned

        true ->
          cleaned
      end

    cond do
      cleaned in ["", ".", "/dev/null", "dev/null"] ->
        nil

      String.starts_with?(cleaned, "/") or String.starts_with?(cleaned, "..") ->
        nil

      String.starts_with?(cleaned, "deps/") or String.starts_with?(cleaned, "_build/") ->
        nil

      String.contains?(cleaned, "://") ->
        nil

      byte_size(cleaned) > 160 ->
        nil

      true ->
        cleaned
    end
  end

  defp workspace_like_subpath?(path) do
    String.starts_with?(path, "lib/") or
      String.starts_with?(path, "test/") or
      String.starts_with?(path, "config/") or
      String.starts_with?(path, "priv/") or
      String.starts_with?(path, "assets/") or
      String.starts_with?(path, "eval/") or
      path in ["mix.exs", "mix.lock", "AGENTS.md", "CLAUDE.md", "CODEX.md"]
  end

  defp build_bounded_summary_lines(turn_lines, [], available_tokens) do
    prune_summary_lines_to_budget(turn_lines, available_tokens)
  end

  defp build_bounded_summary_lines(turn_lines, wm_lines, available_tokens)
       when available_tokens > 0 do
    combined = turn_lines ++ wm_lines

    if estimate_tokens(Enum.join(combined, "\n")) <= available_tokens do
      combined
    else
      wm_budget =
        if turn_lines == [] do
          available_tokens
        else
          # Reserve room for Working memory while leaving budget for recent turn lines when feasible
          min(available_tokens, max(div(available_tokens * 3, 5), min(available_tokens, 36)))
        end

      fitted_wm = fit_working_memory_to_budget(wm_lines, wm_budget)

      if fitted_wm == [] do
        prune_summary_lines_to_budget(turn_lines, available_tokens)
      else
        kept_turns =
          turn_lines
          |> Enum.reverse()
          |> Enum.reduce_while([], fn line, acc ->
            candidate = Enum.join([line | acc] ++ fitted_wm, "\n")

            if estimate_tokens(candidate) <= available_tokens do
              {:cont, [line | acc]}
            else
              {:halt, acc}
            end
          end)

        kept_turns ++ fitted_wm
      end
    end
  end

  defp build_bounded_summary_lines(_turn_lines, _wm_lines, _available_tokens), do: []

  defp fit_working_memory_to_budget([], _budget), do: []
  defp fit_working_memory_to_budget(_wm_lines, budget) when budget <= 0, do: []

  defp fit_working_memory_to_budget(["Working memory:" = header | bullets], budget) do
    full_text = Enum.join([header | bullets], "\n")

    if estimate_tokens(full_text) <= budget do
      [header | bullets]
    else
      # Prioritize Failures -> Patches/Commits -> Files when budget is constrained
      prioritized =
        Enum.sort_by(bullets, fn bullet ->
          cond do
            String.starts_with?(bullet, "- Failures:") -> 1
            String.starts_with?(bullet, "- Patches/Commits:") -> 2
            true -> 3
          end
        end)

      selected =
        Enum.reduce(prioritized, [], fn bullet, acc ->
          candidate = [header | Enum.reverse([bullet | acc])]

          if estimate_tokens(Enum.join(candidate, "\n")) <= budget do
            [bullet | acc]
          else
            case shrink_bullet_to_budget(header, Enum.reverse(acc), bullet, budget) do
              nil -> acc
              shrunk -> [shrunk | acc]
            end
          end
        end)
        |> Enum.reverse()

      if selected == [] do
        []
      else
        # Restore canonical display order: Files, Patches/Commits, Failures
        ordered =
          Enum.sort_by(selected, fn bullet ->
            cond do
              String.starts_with?(bullet, "- Files:") -> 1
              String.starts_with?(bullet, "- Patches/Commits:") -> 2
              true -> 3
            end
          end)

        [header | ordered]
      end
    end
  end

  defp shrink_bullet_to_budget(header, existing, bullet, budget) do
    prefix = Enum.join([header | existing], "\n") <> "\n"
    max_total_bytes = max((budget - 1) * 4 - 1, 0)
    avail_bytes = max_total_bytes - byte_size(prefix)

    if avail_bytes >= 16 do
      shrunk = truncate_line(bullet, avail_bytes)
      candidate = prefix <> shrunk

      if estimate_tokens(candidate) <= budget do
        shrunk
      else
        nil
      end
    else
      nil
    end
  end

  defp prune_summary_lines_to_budget(lines, available_tokens) when available_tokens > 0 do
    total_text = Enum.join(lines, "\n")

    if estimate_tokens(total_text) <= available_tokens do
      lines
    else
      lines
      |> Enum.reverse()
      |> Enum.reduce_while([], fn line, acc ->
        candidate = Enum.join([line | acc], "\n")

        if estimate_tokens(candidate) <= available_tokens do
          {:cont, [line | acc]}
        else
          {:halt, acc}
        end
      end)
    end
  end

  defp prune_summary_lines_to_budget(_lines, _available_tokens), do: []

  defp extract_message_text(msg) when is_map(msg) do
    msg
    |> extract_all_message_texts()
    |> Enum.join("\n")
  end

  defp extract_message_text(_), do: ""

  defp extract_all_message_texts(msg) when is_map(msg) do
    content_texts = extract_texts_from_value(get_message_field(msg, :content))
    parts_texts = extract_texts_from_value(get_message_field(msg, :parts))
    content_texts ++ parts_texts
  end

  defp extract_all_message_texts(_), do: []

  defp extract_texts_from_value(val) when is_binary(val), do: [val]

  defp extract_texts_from_value(val) when is_list(val) do
    Enum.flat_map(val, fn
      item when is_binary(item) ->
        [item]

      item when is_map(item) ->
        cond do
          is_binary(get_message_field(item, :text)) ->
            [get_message_field(item, :text)]

          block_type(item) == "tool_result" ->
            extract_texts_from_value(get_message_field(item, :content))

          has_map_field?(item, :functionResponse) or has_map_field?(item, :function_response) ->
            fr =
              get_message_field(item, :functionResponse) ||
                get_message_field(item, :function_response)

            if is_map(fr) do
              resp = get_message_field(fr, :response)

              cond do
                is_binary(resp) -> [resp]
                is_map(resp) -> Map.values(resp) |> Enum.filter(&is_binary/1)
                true -> []
              end
            else
              []
            end

          has_map_field?(item, :functionCall) or has_map_field?(item, :function_call) ->
            fc =
              get_message_field(item, :functionCall) ||
                get_message_field(item, :function_call)

            name = is_map(fc) && get_message_field(fc, :name)
            if is_binary(name), do: [name], else: []

          block_type(item) == "tool_use" ->
            name = get_message_field(item, :name)
            if is_binary(name), do: [name], else: []

          true ->
            []
        end

      _ ->
        []
    end)
  end

  defp extract_texts_from_value(_), do: []

  defp list_or_empty(val) when is_list(val), do: val
  defp list_or_empty(_), do: []

  # --- Auto Model Window Lookup via Capabilities ---

  defp resolve_auto_window_tokens(settings, model_name) do
    effective_model =
      model_name ||
        raw_setting(settings, :model) ||
        raw_setting(settings, :default_model)

    explicit_provider =
      raw_setting(settings, :provider) ||
        raw_setting(settings, :default_model_provider)

    cond do
      is_binary(effective_model) and String.trim(effective_model) != "" ->
        norm_model = effective_model |> String.trim() |> String.downcase()
        model_base = norm_model |> String.split("/") |> List.last()
        provider = infer_provider(explicit_provider, norm_model, model_base)
        caps = Capabilities.detect(provider, effective_model)
        window_for_capabilities(caps, provider, norm_model, model_base)

      to_string(explicit_provider || "") in ["ollama", "lm_studio", "llama_cpp"] ->
        16_384

      true ->
        @default_window_tokens
    end
  end

  defp infer_provider(explicit_provider, norm_model, model_base) do
    prov = String.downcase(String.trim(to_string(explicit_provider || "")))

    cond do
      prov != "" ->
        prov

      String.starts_with?(model_base, "claude-") ->
        "anthropic"

      String.starts_with?(model_base, "gemini-") or
        model_base in ["carbon", "hydrogen", "argon"] or
        String.starts_with?(model_base, "carbon-") or
        String.starts_with?(model_base, "hydrogen-") or
          String.starts_with?(model_base, "argon-") ->
        "gemini"

      String.starts_with?(norm_model, "ollama/") ->
        "ollama"

      true ->
        "openai"
    end
  end

  defp window_for_capabilities(%Capabilities{} = caps, provider, _norm_model, model_base) do
    tags = List.wrap(caps.tags)

    cond do
      caps.type == :gemini or :gemini_reasoning in tags or
          String.starts_with?(model_base, "gemini-") ->
        1_000_000

      caps.type == :anthropic or caps.provider == "anthropic" or
          String.starts_with?(model_base, "claude-") ->
        200_000

      String.starts_with?(model_base, "gpt-4.1") ->
        1_000_000

      caps.type == :openai and caps.reasoning_supported? ->
        cond do
          String.starts_with?(model_base, "gpt-5") or String.starts_with?(model_base, "codex") ->
            400_000

          :deepseek_reasoning in tags ->
            128_000

          true ->
            200_000
        end

      caps.type == :local ->
        32_768

      provider in ["ollama", "lm_studio", "llama_cpp"] ->
        16_384

      true ->
        @default_window_tokens
    end
  end

  # --- UTF-8 Safe Slicing & Field Helpers ---

  defp utf8_slice_prefix(binary, max_bytes) when is_binary(binary) and max_bytes >= 0 do
    if byte_size(binary) <= max_bytes do
      binary
    else
      slice = binary_part(binary, 0, max_bytes)
      trim_trailing_incomplete_utf8(slice)
    end
  end

  defp utf8_slice_suffix(binary, max_bytes) when is_binary(binary) and max_bytes >= 0 do
    size = byte_size(binary)

    if size <= max_bytes do
      binary
    else
      slice = binary_part(binary, size - max_bytes, max_bytes)
      trim_leading_incomplete_utf8(slice)
    end
  end

  defp trim_trailing_incomplete_utf8(<<>>), do: <<>>

  defp trim_trailing_incomplete_utf8(binary) do
    if String.valid?(binary) do
      binary
    else
      size = byte_size(binary)

      Enum.find_value(1..min(size, 4), "", fn drop ->
        candidate = binary_part(binary, 0, size - drop)
        if String.valid?(candidate), do: candidate
      end)
    end
  end

  defp trim_leading_incomplete_utf8(<<>>), do: <<>>

  defp trim_leading_incomplete_utf8(binary) do
    if String.valid?(binary) do
      binary
    else
      size = byte_size(binary)

      Enum.find_value(1..min(size, 4), "", fn drop ->
        candidate = binary_part(binary, drop, size - drop)
        if String.valid?(candidate), do: candidate
      end)
    end
  end

  defp raw_setting(nil, _field), do: nil

  defp raw_setting(%AppSettings{} = settings, field) do
    Map.get(settings, field)
  end

  defp raw_setting(settings, field) when is_map(settings) do
    case Map.fetch(settings, field) do
      {:ok, val} -> val
      :error -> Map.get(settings, to_string(field))
    end
  end

  defp raw_setting(_other, _field), do: nil

  defp get_setting(nil, _field, default), do: default

  defp get_setting(%AppSettings{} = settings, field, default) do
    case Map.get(settings, field) do
      nil -> default
      val -> val
    end
  end

  defp get_setting(settings, field, default) when is_map(settings) do
    Map.get(settings, field) || Map.get(settings, to_string(field)) || default
  end

  defp get_message_field(map, field) when is_map(map) and is_atom(field) do
    Map.get(map, field) || Map.get(map, Atom.to_string(field))
  end

  defp put_message_field(map, field, val) when is_map(map) and is_atom(field) do
    if Map.has_key?(map, field) do
      Map.put(map, field, val)
    else
      Map.put(map, Atom.to_string(field), val)
    end
  end

  defp atom_keyed?(map) when is_map(map) do
    Enum.any?(Map.keys(map), &is_atom/1)
  end

  defp atom_keyed?(_), do: true
end

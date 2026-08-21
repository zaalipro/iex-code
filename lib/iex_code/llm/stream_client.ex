defmodule IexCode.LLM.StreamClient do
  @moduledoc """
  Multi-provider SSE streaming HTTP client.
  Integrates Req response streaming with UTF8Buffer and SSEParser, triggers incremental
  callbacks, and accumulates the complete response struct with merged tool call arguments.

  All parsing and `on_chunk` callbacks run in the calling process while Req streams the
  response (no helper process is spawned), so a raising callback aborts the stream with
  an error instead of deadlocking.
  """
  require Logger
  alias IexCode.LLM.{UTF8Buffer, SSEParser}

  defstruct [
    :provider,
    :url,
    :headers,
    :body,
    :on_chunk,
    :receive_timeout
  ]

  @stream_state_key :iex_code_llm_stream_state

  @type tool_call :: %{
          id: String.t(),
          name: String.t(),
          args: map()
        }

  @type stream_response :: %{
          text: String.t(),
          tool_calls: [tool_call()],
          reasoning: String.t(),
          stop_reason: String.t() | atom() | nil,
          raw: map()
        }

  @doc """
  Streams a request to the configured LLM endpoint and accumulates the final response.

  ## Options
  - `:provider` - "openai" (default) or "anthropic"
  - `:url` - full endpoint URL
  - `:headers` - HTTP headers list
  - `:body` - map to be encoded as JSON (with `stream: true`)
  - `:receive_timeout` - HTTP receive timeout in ms (default: 60_000)
  - `:cancelled?` - optional zero-arity fun polled between chunks; when it returns
    truthy the stream is aborted cleanly and the partial response is returned

  On HTTP failures a structured error map is returned:
  `{:error, %{status: integer, body: binary, kind: atom, message: binary}}` where `kind`
  is one of `:rate_limit | :auth | :server | :network | :bad_request`.
  """
  @spec stream(map() | keyword(), (String.t() | map() -> any())) ::
          {:ok, stream_response()} | {:error, term()}
  def stream(request_opts, on_chunk \\ fn _c -> :ok end) do
    opts_map = if is_list(request_opts), do: Map.new(request_opts), else: request_opts

    provider = Map.get(opts_map, :provider, "openai")
    url = Map.fetch!(opts_map, :url)
    headers = Map.get(opts_map, :headers, [])
    body = Map.fetch!(opts_map, :body) |> Map.put("stream", true)
    receive_timeout = Map.get(opts_map, :receive_timeout, 60_000)
    # A nil value (key present, no fun provided) must behave like an absent key.
    cancelled? = Map.get(opts_map, :cancelled?) || fn -> false end

    initial_state = new_state(provider)

    into_fun = fn
      {:data, raw_chunk}, {req, resp} ->
        state = get_stream_state(resp, initial_state)

        cond do
          cancelled?.() ->
            # abort cleanly between chunks; the partial result is still returned
            {:halt, {req, put_stream_state(resp, %{state | cancelled?: true})}}

          resp.status != 200 ->
            # accumulate the error body (it is not collected into resp.body
            # when streaming with an :into fun)
            error_io = [raw_chunk | state.error_io]
            {:cont, {req, put_stream_state(resp, %{state | error_io: error_io})}}

          true ->
            case consume_chunk(state, raw_chunk, on_chunk) do
              {:ok, next_state} ->
                {:cont, {req, put_stream_state(resp, next_state)}}

              {:error, error_state} ->
                # a raising on_chunk kills the stream instead of deadlocking it
                {:halt, {req, put_stream_state(resp, error_state)}}
            end
        end
    end

    http_result =
      Req.post(
        url,
        json: body,
        headers: headers,
        into: into_fun,
        receive_timeout: receive_timeout,
        retry: false
      )

    case http_result do
      {:ok, %{status: 200} = resp} ->
        state = get_stream_state(resp, initial_state)

        state =
          try do
            flush_tail(state, on_chunk)
          rescue
            e -> %{state | error: e}
          end

        if state.error do
          {:error, state.error}
        else
          {:ok, assemble_final_response(state)}
        end

      {:ok, %{status: status} = resp} ->
        state = get_stream_state(resp, initial_state)
        error_body = state.error_io |> Enum.reverse() |> IO.iodata_to_binary()

        error_body =
          if(error_body == "" and is_binary(resp.body), do: resp.body, else: error_body)

        {:error,
         %{
           status: status,
           body: error_body,
           kind: error_kind(status),
           message: "HTTP #{status}"
         }}

      {:error, exception} ->
        message = Exception.message(exception)
        {:error, %{status: 0, body: message, kind: :network, message: message}}
    end
  end

  # --- Internal Chunk Handling ---

  defp new_state(provider) do
    %{
      provider: provider,
      utf8_state: UTF8Buffer.new(),
      sse_state: SSEParser.new(),
      text_io: [],
      reasoning_io: [],
      tool_calls_acc: %{},
      usage: nil,
      stop_reason: nil,
      error: nil,
      error_io: [],
      cancelled?: false
    }
  end

  defp consume_chunk(state, raw_chunk, on_chunk) do
    {valid_text, next_utf8} = UTF8Buffer.process_bytes(state.utf8_state, raw_chunk)
    {events, next_sse} = SSEParser.parse(state.sse_state, valid_text)

    try do
      next_state =
        Enum.reduce(events, %{state | utf8_state: next_utf8, sse_state: next_sse}, fn ev, st ->
          apply_event(ev, st, on_chunk)
        end)

      {:ok, next_state}
    rescue
      e -> {:error, %{state | error: e}}
    end
  end

  # Emits anything still buffered at end-of-stream so the last event or a
  # truncated multibyte tail is not lost.
  defp flush_tail(state, on_chunk) do
    {tail_text, <<>>} = UTF8Buffer.flush(state.utf8_state)
    {events, next_sse} = SSEParser.parse(state.sse_state, tail_text <> "\n")

    Enum.reduce(events, %{state | utf8_state: <<>>, sse_state: next_sse}, fn ev, st ->
      apply_event(ev, st, on_chunk)
    end)
  end

  defp apply_event(ev, st, on_chunk) do
    case SSEParser.parse_event(ev, st.provider) do
      {:delta, delta} ->
        text = delta[:text] || ""
        if text != "", do: on_chunk.(text)

        %{
          st
          | text_io: [text | st.text_io],
            reasoning_io: [delta[:reasoning] || "" | st.reasoning_io],
            tool_calls_acc: accumulate_tool_calls(st.tool_calls_acc, delta[:tool_calls] || []),
            usage: merge_usage(st.usage, delta[:usage])
        }

      {:done, reason, final_delta} ->
        text = final_delta[:text] || ""
        if text != "", do: on_chunk.(text)

        %{
          st
          | text_io: [text | st.text_io],
            reasoning_io: [final_delta[:reasoning] || "" | st.reasoning_io],
            tool_calls_acc:
              accumulate_tool_calls(st.tool_calls_acc, final_delta[:tool_calls] || []),
            stop_reason: st.stop_reason || reason,
            usage: merge_usage(st.usage, final_delta[:usage])
        }

      {:done, reason} ->
        # keep an already-captured stop_reason (finish_reason / message_delta);
        # [DONE] and message_stop must not overwrite it
        %{st | stop_reason: st.stop_reason || reason}

      {:error, err} ->
        %{st | error: err}

      :ignore ->
        st
    end
  end

  defp accumulate_tool_calls(acc, []), do: acc

  defp accumulate_tool_calls(acc, [tc | rest]) do
    idx = tool_call_index(tc, acc)
    existing = Map.get(acc, idx, %{id: nil, name: nil, args_io: []})

    id = tc["id"] || existing.id
    name = get_in(tc, ["function", "name"]) || tc["name"] || existing.name
    args_delta = get_in(tc, ["function", "arguments"]) || tc["partial_json"] || ""

    updated = %{
      id: id,
      name: name,
      args_io: [args_delta | existing.args_io]
    }

    accumulate_tool_calls(Map.put(acc, idx, updated), rest)
  end

  # Keys parallel tool calls by their stream index. When a provider omits the
  # index, fall back to matching the tool call id, then to the newest entry for
  # continuation deltas, so a single call is neither split across entries nor
  # merged with a sibling call.
  defp tool_call_index(%{"index" => idx}, _acc) when is_integer(idx), do: idx

  defp tool_call_index(tc, acc) do
    id = tc["id"]

    case id && Enum.find_value(acc, fn {idx, entry} -> if entry.id == id, do: idx end) do
      idx when is_integer(idx) ->
        idx

      _ ->
        if id == nil and map_size(acc) > 0 do
          acc |> Map.keys() |> Enum.max()
        else
          map_size(acc)
        end
    end
  end

  defp assemble_final_response(state) do
    final_tool_calls =
      state.tool_calls_acc
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_idx, tc} ->
        args_raw = tc.args_io |> Enum.reverse() |> IO.iodata_to_binary()

        args =
          if args_raw != "" do
            case Jason.decode(args_raw) do
              {:ok, map} when is_map(map) -> map
              _ -> %{"raw" => args_raw}
            end
          else
            %{}
          end

        %{
          id: tc.id || "call_#{:erlang.unique_integer([:positive])}",
          name: tc.name || "unknown",
          args: args
        }
      end)

    %{
      text: state.text_io |> Enum.reverse() |> IO.iodata_to_binary(),
      tool_calls: final_tool_calls,
      reasoning: state.reasoning_io |> Enum.reverse() |> IO.iodata_to_binary(),
      stop_reason: state.stop_reason || if(state.cancelled?, do: :cancelled),
      raw: raw_map(state.usage)
    }
  end

  defp raw_map(nil), do: %{}
  defp raw_map(usage), do: %{"usage" => usage}

  defp merge_usage(nil, nil), do: nil
  defp merge_usage(existing, nil), do: existing
  defp merge_usage(nil, new_usage), do: new_usage
  defp merge_usage(existing, new_usage), do: Map.merge(existing, new_usage)

  defp error_kind(401), do: :auth
  defp error_kind(403), do: :auth
  defp error_kind(429), do: :rate_limit
  defp error_kind(status) when status >= 400 and status < 500, do: :bad_request
  defp error_kind(status) when status >= 500, do: :server
  defp error_kind(_), do: :bad_request

  # --- Stream State (threaded through Req's response accumulator) ---

  defp get_stream_state(resp, default) do
    Map.get(resp.private, @stream_state_key, default)
  end

  defp put_stream_state(resp, state) do
    put_in(resp.private[@stream_state_key], state)
  end
end

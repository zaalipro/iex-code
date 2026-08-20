defmodule IexCode.LLM.StreamClient do
  @moduledoc """
  Multi-provider SSE streaming HTTP client.
  Integrates Req response streaming with UTF8Buffer and SSEParser, triggers incremental
  callbacks, and accumulates the complete response struct with merged tool call arguments.
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

    {:ok, state_agent} =
      Agent.start_link(fn ->
        %{
          utf8_state: UTF8Buffer.new(),
          sse_state: SSEParser.new(),
          text_acc: "",
          reasoning_acc: "",
          tool_calls_acc: %{},
          stop_reason: nil,
          error: nil
        }
      end)

    into_fun = fn {:data, raw_chunk}, {req, resp} ->
      handle_chunk(raw_chunk, provider, on_chunk, state_agent)
      {:cont, {req, resp}}
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

    final_state = Agent.get(state_agent, & &1)
    Agent.stop(state_agent)

    case http_result do
      {:ok, %{status: 200}} ->
        if final_state.error do
          {:error, final_state.error}
        else
          {:ok, assemble_final_response(final_state)}
        end

      {:ok, %{status: status, body: resp_body}} ->
        {:error, %{status: status, body: resp_body, message: "HTTP #{status}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Internal Chunk Handler ---

  defp handle_chunk(raw_chunk, provider, on_chunk, state_agent) do
    Agent.update(state_agent, fn state ->
      {valid_text, next_utf8} = UTF8Buffer.process_bytes(state.utf8_state, raw_chunk)
      {events, next_sse} = SSEParser.parse(state.sse_state, valid_text)

      Enum.reduce(events, %{state | utf8_state: next_utf8, sse_state: next_sse}, fn ev, acc_st ->
        case SSEParser.parse_event(ev, provider) do
          {:delta, %{text: t, tool_calls: tc_chunks, reasoning: r}} ->
            if t != "" do
              on_chunk.(t)
            end

            next_tc = accumulate_tool_calls(acc_st.tool_calls_acc, tc_chunks)

            %{
              acc_st
              | text_acc: acc_st.text_acc <> t,
                reasoning_acc: acc_st.reasoning_acc <> r,
                tool_calls_acc: next_tc
            }

          {:done, reason, final_delta} ->
            if final_delta[:text] && final_delta.text != "" do
              on_chunk.(final_delta.text)
            end

            next_tc = accumulate_tool_calls(acc_st.tool_calls_acc, final_delta[:tool_calls] || [])

            %{
              acc_st
              | text_acc: acc_st.text_acc <> (final_delta[:text] || ""),
                reasoning_acc: acc_st.reasoning_acc <> (final_delta[:reasoning] || ""),
                tool_calls_acc: next_tc,
                stop_reason: reason
            }

          {:done, reason} ->
            %{acc_st | stop_reason: reason}

          {:error, err} ->
            %{acc_st | error: err}

          _ ->
            acc_st
        end
      end)
    end)
  end

  defp accumulate_tool_calls(acc, []), do: acc

  defp accumulate_tool_calls(acc, [tc | rest]) do
    idx = tc["index"] || map_size(acc)
    existing = Map.get(acc, idx, %{id: nil, name: nil, args_raw: ""})

    id = tc["id"] || existing.id
    name = get_in(tc, ["function", "name"]) || tc["name"] || existing.name
    args_delta = get_in(tc, ["function", "arguments"]) || tc["partial_json"] || ""

    updated = %{
      id: id,
      name: name,
      args_raw: existing.args_raw <> args_delta
    }

    accumulate_tool_calls(Map.put(acc, idx, updated), rest)
  end

  defp assemble_final_response(state) do
    final_tool_calls =
      state.tool_calls_acc
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_idx, tc} ->
        args =
          if tc.args_raw != "" do
            case Jason.decode(tc.args_raw) do
              {:ok, map} when is_map(map) -> map
              _ -> %{"raw" => tc.args_raw}
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
      text: state.text_acc,
      tool_calls: final_tool_calls,
      reasoning: state.reasoning_acc,
      stop_reason: state.stop_reason,
      raw: %{}
    }
  end
end

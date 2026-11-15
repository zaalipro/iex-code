defmodule IexCode.LLM.Gemini do
  @moduledoc """
  Native Google Gemini `v1beta` REST & SSE client supporting Gemini 2.5, 3, and 4
  frontier models, thinking budgets (`thinkingConfig`), thought-part extraction,
  multi-turn `functionCall` / `functionResponse` tool loops, and cancellation.
  """
  require Logger

  alias IexCode.LLM.{Capabilities, SSEParser, UTF8Buffer}

  @default_base_url "https://generativelanguage.googleapis.com/v1beta"
  @default_model "gemini-2.5-pro"
  @default_receive_timeout 60_000
  @stream_state_key :iex_code_gemini_stream_state
  @max_success_stream_bytes 2_000_000
  @max_error_body_bytes 64_000

  def chat(messages, system_prompt, opts, on_chunk \\ fn _c -> :ok end) do
    with {:ok, prepared} <-
           IexCode.LLM.RequestPreparation.prepare(__MODULE__, messages, system_prompt, opts) do
      send_prepared(prepared.body, opts, on_chunk)
    end
  end

  @doc false
  def build_body(messages, system_prompt, opts) do
    model = Keyword.get(opts, :model, @default_model)
    temperature = Keyword.get(opts, :temperature, 0.2)
    max_tokens = Keyword.get(opts, :max_tokens, 4096)
    tools = Keyword.get(opts, :tools, [])

    {system_messages, conversation_messages} =
      Enum.split_with(messages, fn msg ->
        role_string(msg) in ["system", "developer"]
      end)

    combined_system =
      [system_prompt | Enum.map(system_messages, &extract_text_content/1)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")

    call_id_to_name = build_call_id_map(conversation_messages)

    contents =
      conversation_messages
      |> Enum.map(&format_content(&1, call_id_to_name))
      |> merge_consecutive_contents()

    caps = Capabilities.detect("gemini", model)
    reasoning_effort = Keyword.get(opts, :reasoning_effort)
    raw_budget = Keyword.get(opts, :thinking_budget) || Keyword.get(opts, :budget_tokens)
    thinking_opt = Keyword.get(opts, :thinking_config) || Keyword.get(opts, :thinking)

    {effective_max_tokens, thinking_config} =
      resolve_thinking_config(caps, max_tokens, reasoning_effort, raw_budget, thinking_opt)

    generation_config =
      %{"maxOutputTokens" => effective_max_tokens}
      |> put_optional("temperature", temperature)
      |> put_optional("thinkingConfig", thinking_config)

    %{"contents" => contents, "generationConfig" => generation_config}
    |> put_system_instruction(combined_system)
    |> put_tools(tools)
  end

  @doc false
  def send_prepared(body, opts, on_chunk) do
    api_key = Keyword.get(opts, :api_key, "")
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    model = Keyword.get(opts, :model, @default_model)
    stream? = Keyword.get(opts, :stream, true)
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)
    cancelled? = Keyword.get(opts, :cancelled?) || fn -> false end
    req_options = Keyword.get(opts, :req_options, [])

    if api_key in [nil, ""] do
      {:error, :no_api_key}
    else
      headers = [
        {"x-goog-api-key", api_key},
        {"content-type", "application/json"}
      ]

      url = endpoint_url(base_url, model, stream?)

      if stream? do
        stream_request(
          url,
          headers,
          body,
          receive_timeout,
          cancelled?,
          req_options,
          api_key,
          on_chunk
        )
      else
        post_request(
          url,
          headers,
          body,
          receive_timeout,
          cancelled?,
          req_options,
          api_key,
          on_chunk
        )
      end
    end
  end

  # --- Transport ---

  defp stream_request(
         url,
         headers,
         body,
         receive_timeout,
         cancelled?,
         req_options,
         api_key,
         on_chunk
       ) do
    initial_state = new_stream_state()

    into_fun = fn
      {:data, raw_chunk}, {req, resp} ->
        state = get_stream_state(resp, initial_state)

        cond do
          cancelled?.() ->
            {:halt, {req, put_stream_state(resp, %{state | cancelled?: true})}}

          resp.status != 200 ->
            {next_state, directive} = append_error_chunk(state, raw_chunk)
            {directive, {req, put_stream_state(resp, next_state)}}

          true ->
            case account_success_chunk(state, raw_chunk) do
              {:ok, bounded_state} ->
                case consume_sse_chunk(bounded_state, raw_chunk, on_chunk) do
                  {:ok, next_state} ->
                    {:cont, {req, put_stream_state(resp, next_state)}}

                  {:error, error_state} ->
                    {:halt, {req, put_stream_state(resp, error_state)}}
                end

              {:error, error_state} ->
                {:halt, {req, put_stream_state(resp, error_state)}}
            end
        end
    end

    req_opts =
      [
        json: body,
        headers: headers,
        into: into_fun,
        receive_timeout: receive_timeout,
        retry: false
      ] ++ req_options

    http_result =
      try do
        if cancelled?.() do
          {:cancelled_before_send, initial_state}
        else
          Req.post(url, req_opts)
        end
      rescue
        exception -> {:request_exception, exception}
      catch
        kind, reason -> {:request_failure, kind, reason}
      end

    case http_result do
      {:cancelled_before_send, state} ->
        {:ok, assemble_stream_response(%{state | cancelled?: true})}

      {:ok, %{status: 200} = resp} ->
        state = get_stream_state(resp, initial_state)

        state =
          if state.error || state.cancelled? do
            state
          else
            try do
              flush_sse_tail(state, on_chunk)
            rescue
              e -> %{state | error: e}
            end
          end

        if state.error do
          {:error,
           %{
             status: nil,
             body: sanitize_secret(reason_to_string(state.error), api_key),
             kind: :network
           }}
        else
          {:ok, assemble_stream_response(state)}
        end

      {:ok, %{status: status} = resp} ->
        state = get_stream_state(resp, initial_state)
        error_body = extract_stream_error_body(state, resp.body)

        {:error,
         %{
           status: status,
           body: sanitize_secret(error_body, api_key),
           kind: kind_for_status(status)
         }}

      {:error, reason} ->
        {:error,
         %{
           status: nil,
           body: sanitize_secret(reason_to_string(reason), api_key),
           kind: :network
         }}

      {:request_exception, exception} ->
        {:error,
         %{
           status: nil,
           body: sanitize_secret(Exception.message(exception), api_key),
           kind: :network
         }}

      {:request_failure, kind, reason} ->
        {:error,
         %{
           status: nil,
           body: sanitize_secret("#{kind}: #{reason_to_string(reason)}", api_key),
           kind: :network
         }}
    end
  end

  defp post_request(
         url,
         headers,
         body,
         receive_timeout,
         cancelled?,
         req_options,
         api_key,
         on_chunk
       ) do
    if cancelled?.() do
      {:ok,
       %{
         text: "",
         reasoning: nil,
         tool_calls: [],
         stop_reason: :cancelled,
         raw: %{},
         usage: empty_usage()
       }}
    else
      req_opts =
        [
          json: body,
          headers: headers,
          receive_timeout: receive_timeout,
          retry: false
        ] ++ req_options

      case Req.post(url, req_opts) do
        {:ok, %{status: 200, body: resp}} when is_map(resp) ->
          {text, reasoning_str, tool_calls, stop_reason} = extract_candidates(resp)

          if text != "", do: on_chunk.(text)

          {:ok,
           %{
             text: text,
             reasoning: if(reasoning_str != "", do: reasoning_str, else: nil),
             tool_calls: tool_calls,
             stop_reason: stop_reason,
             raw: resp,
             usage: extract_usage(resp["usageMetadata"])
           }}

        {:ok, %{status: 200, body: raw_body}} when is_binary(raw_body) ->
          case Jason.decode(raw_body) do
            {:ok, resp} when is_map(resp) ->
              {text, reasoning_str, tool_calls, stop_reason} = extract_candidates(resp)
              if text != "", do: on_chunk.(text)

              {:ok,
               %{
                 text: text,
                 reasoning: if(reasoning_str != "", do: reasoning_str, else: nil),
                 tool_calls: tool_calls,
                 stop_reason: stop_reason,
                 raw: resp,
                 usage: extract_usage(resp["usageMetadata"])
               }}

            {:error, decode_err} ->
              {:error,
               %{
                 status: 200,
                 body: sanitize_secret(reason_to_string(decode_err), api_key),
                 kind: :bad_request
               }}
          end

        {:ok, %{status: status, body: body_resp}} ->
          {:error,
           %{
             status: status,
             body: sanitize_secret(body_to_string(body_resp), api_key),
             kind: kind_for_status(status)
           }}

        {:error, reason} ->
          {:error,
           %{
             status: nil,
             body: sanitize_secret(reason_to_string(reason), api_key),
             kind: :network
           }}
      end
    end
  end

  # --- SSE Parsing & Accumulation ---

  defp new_stream_state do
    %{
      utf8_state: UTF8Buffer.new(),
      sse_state: SSEParser.new(),
      text_io: [],
      reasoning_io: [],
      tool_calls: [],
      usage: nil,
      stop_reason: nil,
      last_raw: nil,
      error: nil,
      error_io: [],
      error_bytes: 0,
      error_truncated?: false,
      success_bytes: 0,
      cancelled?: false
    }
  end

  defp consume_sse_chunk(state, raw_chunk, on_chunk) do
    {valid_text, next_utf8} = UTF8Buffer.process_bytes(state.utf8_state, raw_chunk)
    {events, next_sse} = SSEParser.parse(state.sse_state, valid_text)

    try do
      next_state =
        Enum.reduce(events, %{state | utf8_state: next_utf8, sse_state: next_sse}, fn ev, st ->
          apply_sse_event(ev, st, on_chunk)
        end)

      {:ok, next_state}
    rescue
      e -> {:error, %{state | error: e}}
    end
  end

  defp flush_sse_tail(state, on_chunk) do
    {tail_text, <<>>} = UTF8Buffer.flush(state.utf8_state)
    {events, next_sse} = SSEParser.parse(state.sse_state, tail_text <> "\n\n")

    Enum.reduce(events, %{state | utf8_state: <<>>, sse_state: next_sse}, fn ev, st ->
      apply_sse_event(ev, st, on_chunk)
    end)
  end

  defp apply_sse_event(%{data: data}, st, on_chunk) do
    trimmed = String.trim(data || "")

    cond do
      trimmed == "" ->
        st

      trimmed == "[DONE]" ->
        %{st | stop_reason: st.stop_reason || :stop}

      true ->
        case Jason.decode(trimmed) do
          {:ok, %{"error" => err}} ->
            %{st | error: err}

          {:ok, payload} when is_map(payload) ->
            {text, reasoning, calls, finish_reason} = extract_candidates(payload)
            if text != "", do: on_chunk.(text)

            merged_usage = merge_usage_metadata(st.usage, payload["usageMetadata"])

            %{
              st
              | text_io: if(text != "", do: [text | st.text_io], else: st.text_io),
                reasoning_io:
                  if(reasoning != "", do: [reasoning | st.reasoning_io], else: st.reasoning_io),
                tool_calls: st.tool_calls ++ calls,
                usage: merged_usage,
                stop_reason: finish_reason || st.stop_reason,
                last_raw: payload
            }

          {:error, err} ->
            %{st | error: err}
        end
    end
  end

  defp assemble_stream_response(state) do
    text = state.text_io |> Enum.reverse() |> IO.iodata_to_binary()
    reasoning_str = state.reasoning_io |> Enum.reverse() |> IO.iodata_to_binary()

    raw =
      cond do
        is_map(state.last_raw) and is_map(state.usage) ->
          Map.put(state.last_raw, "usageMetadata", state.usage)

        is_map(state.last_raw) ->
          state.last_raw

        is_map(state.usage) ->
          %{"usageMetadata" => state.usage}

        true ->
          %{}
      end

    %{
      text: text,
      reasoning: if(reasoning_str != "", do: reasoning_str, else: nil),
      tool_calls: state.tool_calls,
      stop_reason: if(state.cancelled?, do: :cancelled, else: state.stop_reason),
      raw: raw,
      usage: extract_usage(state.usage)
    }
  end

  defp extract_candidates(payload) when is_map(payload) do
    candidates = payload["candidates"] || []
    first = List.first(candidates) || %{}
    parts = get_in(first, ["content", "parts"]) || []
    finish_reason = first["finishReason"]

    {text_io, reasoning_io, calls_rev} =
      Enum.reduce(parts, {[], [], []}, fn part, {t_acc, r_acc, c_acc} ->
        cond do
          is_map(part) and part["thought"] == true ->
            {t_acc, [part["text"] || "" | r_acc], c_acc}

          is_map(part) and is_map(part["functionCall"]) ->
            fc = part["functionCall"]

            call = %{
              id: fc["id"] || "call_#{:erlang.unique_integer([:positive])}",
              name: fc["name"] || "unknown",
              args: normalize_call_args(fc["args"])
            }

            {t_acc, r_acc, [call | c_acc]}

          is_map(part) and is_binary(part["text"]) ->
            {[part["text"] | t_acc], r_acc, c_acc}

          true ->
            {t_acc, r_acc, c_acc}
        end
      end)

    {
      text_io |> Enum.reverse() |> IO.iodata_to_binary(),
      reasoning_io |> Enum.reverse() |> IO.iodata_to_binary(),
      Enum.reverse(calls_rev),
      finish_reason
    }
  end

  defp normalize_call_args(args) when is_map(args), do: args

  defp normalize_call_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp normalize_call_args(_), do: %{}

  # --- Request Formatting Helpers ---

  defp resolve_thinking_config(caps, max_tokens, reasoning_effort, raw_budget, thinking_opt) do
    cond do
      is_map(thinking_opt) and is_integer(thinking_opt["thinkingBudget"]) ->
        budget = thinking_opt["thinkingBudget"]

        if budget <= 0 do
          {max_tokens, %{"thinkingBudget" => 0}}
        else
          clamped = max(budget, caps.min_budget || 1024)
          {max(max_tokens, clamped + 1024), Map.put_new(thinking_opt, "includeThoughts", true)}
        end

      reasoning_effort in ["none", :none] or raw_budget == 0 ->
        if caps.reasoning_supported? or raw_budget == 0 do
          {max_tokens, %{"thinkingBudget" => 0}}
        else
          {max_tokens, nil}
        end

      caps.reasoning_supported? or (is_integer(raw_budget) and raw_budget > 0) ->
        budget =
          if is_integer(raw_budget) do
            raw_budget
          else
            caps.default_budget || 4096
          end

        clamped_budget = max(budget, caps.min_budget || 1024)
        clamped_max = max(max_tokens, clamped_budget + 1024)
        {clamped_max, %{"thinkingBudget" => clamped_budget, "includeThoughts" => true}}

      true ->
        {max_tokens, nil}
    end
  end

  defp build_call_id_map(messages) do
    Enum.reduce(messages, %{}, fn msg, acc ->
      msg
      |> field(:tool_calls)
      |> List.wrap()
      |> Enum.reduce(acc, fn tc, inner_acc ->
        id = field(tc, :id)
        name = field(tc, :name) || get_in(tc, ["function", "name"])
        if is_binary(id) and is_binary(name), do: Map.put(inner_acc, id, name), else: inner_acc
      end)
    end)
  end

  defp format_content(%{"parts" => parts} = msg, _call_id_to_name) when is_list(parts) do
    role = if role_string(msg) in ["assistant", "model"], do: "model", else: "user"
    %{"role" => role, "parts" => parts}
  end

  defp format_content(%{parts: parts} = msg, _call_id_to_name) when is_list(parts) do
    role = if role_string(msg) in ["assistant", "model"], do: "model", else: "user"
    %{"role" => role, "parts" => parts}
  end

  defp format_content(msg, call_id_to_name) when is_map(msg) do
    case role_string(msg) do
      role when role in ["assistant", "model"] ->
        thought = field(msg, :thought)
        content = field(msg, :content)
        tool_calls = List.wrap(field(msg, :tool_calls))

        thought_parts =
          if is_binary(thought) and thought != "" do
            [%{"thought" => true, "text" => thought}]
          else
            []
          end

        call_parts =
          Enum.map(tool_calls, fn tc ->
            name = field(tc, :name) || get_in(tc, ["function", "name"]) || "unknown"
            args = decode_args(field(tc, :args) || get_in(tc, ["function", "arguments"]))
            part = %{"functionCall" => %{"name" => name, "args" => args}}

            case field(tc, :thought_signature) || field(tc, :thoughtSignature) do
              sig when is_binary(sig) and sig != "" -> Map.put(part, "thoughtSignature", sig)
              _ -> part
            end
          end)

        text_parts =
          cond do
            is_binary(content) and content != "" ->
              [%{"text" => content}]

            thought_parts == [] and call_parts == [] ->
              [%{"text" => to_string(content || "")}]

            true ->
              []
          end

        %{"role" => "model", "parts" => thought_parts ++ text_parts ++ call_parts}

      role when role in ["tool", "function"] ->
        call_id = field(msg, :tool_call_id)

        name =
          field(msg, :name) ||
            field(msg, :tool_name) ||
            (call_id && Map.get(call_id_to_name, call_id)) ||
            call_id ||
            "tool"

        raw_response = field(msg, :response) || field(msg, :content)

        response_map =
          cond do
            is_map(raw_response) -> raw_response
            true -> %{"result" => to_string(raw_response || "")}
          end

        %{
          "role" => "user",
          "parts" => [
            %{
              "functionResponse" => %{
                "name" => name,
                "response" => response_map
              }
            }
          ]
        }

      _user ->
        %{"role" => "user", "parts" => [%{"text" => extract_text_content(msg)}]}
    end
  end

  defp format_content(other, _call_id_to_name) do
    %{"role" => "user", "parts" => [%{"text" => to_string(other)}]}
  end

  defp merge_consecutive_contents(contents) do
    contents
    |> Enum.reverse()
    |> Enum.reduce([], fn
      item, [%{"role" => role} = prev | rest] ->
        if role == item["role"] do
          merged = %{"role" => role, "parts" => (item["parts"] || []) ++ (prev["parts"] || [])}
          [merged | rest]
        else
          [item | [prev | rest]]
        end

      item, acc ->
        [item | acc]
    end)
  end

  defp put_system_instruction(map, ""), do: map

  defp put_system_instruction(map, system_prompt) when is_binary(system_prompt) do
    Map.put(map, "systemInstruction", %{"parts" => [%{"text" => system_prompt}]})
  end

  defp put_tools(map, []), do: map

  defp put_tools(map, tools) when is_list(tools) do
    case tools do
      [%{"functionDeclarations" => _} | _] ->
        Map.put(map, "tools", tools)

      _ ->
        declarations =
          Enum.map(tools, fn
            %{name: name, description: desc, parameters: params} ->
              build_function_declaration(name, desc, params)

            %{"type" => "function", "function" => fn_map} when is_map(fn_map) ->
              build_function_declaration(
                fn_map["name"],
                fn_map["description"],
                fn_map["parameters"]
              )

            %{"name" => name} = t ->
              build_function_declaration(
                name,
                t["description"],
                t["parameters"] || t["input_schema"]
              )

            other ->
              other
          end)

        Map.put(map, "tools", [%{"functionDeclarations" => declarations}])
    end
  end

  defp build_function_declaration(name, description, parameters) do
    base = %{"name" => name, "description" => description || ""}

    case sanitize_schema(parameters) do
      nil -> base
      schema when schema == %{} -> base
      schema -> Map.put(base, "parameters", schema)
    end
  end

  defp sanitize_schema(nil), do: nil

  defp sanitize_schema(schema) when is_map(schema) do
    schema
    |> Enum.reject(fn {k, _v} -> to_string(k) == "additionalProperties" end)
    |> Map.new(fn {k, v} -> {to_string(k), sanitize_schema(v)} end)
  end

  defp sanitize_schema(schema) when is_list(schema), do: Enum.map(schema, &sanitize_schema/1)
  defp sanitize_schema(other), do: other

  defp endpoint_url(base_url, model, true) do
    "#{String.trim_trailing(base_url, "/")}/models/#{normalize_model_id(model)}:streamGenerateContent?alt=sse"
  end

  defp endpoint_url(base_url, model, false) do
    "#{String.trim_trailing(base_url, "/")}/models/#{normalize_model_id(model)}:generateContent"
  end

  defp normalize_model_id(model) when is_binary(model) do
    trimmed = String.trim(model)

    cond do
      String.starts_with?(trimmed, "models/") -> String.replace_prefix(trimmed, "models/", "")
      String.contains?(trimmed, "/") -> List.last(String.split(trimmed, "/"))
      true -> trimmed
    end
  end

  defp decode_args(args) when is_map(args), do: args

  defp decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_args(_), do: %{}

  defp role_string(msg) when is_map(msg), do: to_string(field(msg, :role) || "user")
  defp role_string(_), do: "user"

  defp extract_text_content(msg) when is_map(msg) do
    case field(msg, :content) do
      text when is_binary(text) -> text
      nil -> ""
      other -> to_string(other)
    end
  end

  defp extract_text_content(other), do: to_string(other || "")

  defp field(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_map, _key), do: nil

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  # --- Usage & Error Helpers ---

  defp merge_usage_metadata(nil, nil), do: nil
  defp merge_usage_metadata(existing, nil), do: existing
  defp merge_usage_metadata(nil, incoming) when is_map(incoming), do: incoming

  defp merge_usage_metadata(existing, incoming) when is_map(existing) and is_map(incoming),
    do: Map.merge(existing, incoming)

  defp extract_usage(usage) when is_map(usage) do
    prompt = usage["promptTokenCount"] || usage["prompt_tokens"] || 0
    candidates = usage["candidatesTokenCount"] || usage["completion_tokens"] || 0
    thoughts = usage["thoughtsTokenCount"] || 0
    completion = candidates + thoughts
    total = usage["totalTokenCount"] || usage["total_tokens"] || prompt + completion

    %{
      prompt_tokens: prompt,
      completion_tokens: completion,
      thoughts_tokens: thoughts,
      total_tokens: total
    }
  end

  defp extract_usage(_), do: empty_usage()

  defp empty_usage do
    %{prompt_tokens: 0, completion_tokens: 0, thoughts_tokens: 0, total_tokens: 0}
  end

  defp account_success_chunk(state, chunk) when is_binary(chunk) do
    received = state.success_bytes + byte_size(chunk)

    if received <= @max_success_stream_bytes do
      {:ok, %{state | success_bytes: received}}
    else
      {:error, %{state | error: :response_too_large, success_bytes: received}}
    end
  end

  defp append_error_chunk(state, chunk) when is_binary(chunk) do
    remaining = max(@max_error_body_bytes - state.error_bytes, 0)

    cond do
      byte_size(chunk) <= remaining ->
        {%{
           state
           | error_io: [chunk | state.error_io],
             error_bytes: state.error_bytes + byte_size(chunk)
         }, :cont}

      remaining > 0 ->
        prefix = binary_part(chunk, 0, remaining)

        {%{
           state
           | error_io: [prefix | state.error_io],
             error_bytes: @max_error_body_bytes,
             error_truncated?: true
         }, :halt}

      true ->
        {%{state | error_truncated?: true}, :halt}
    end
  end

  defp extract_stream_error_body(state, resp_body) do
    if state.error_truncated? do
      "Upstream error body exceeded #{@max_error_body_bytes} bytes"
    else
      captured = state.error_io |> Enum.reverse() |> IO.iodata_to_binary()

      cond do
        captured != "" ->
          captured

        is_binary(resp_body) ->
          binary_part(resp_body, 0, min(byte_size(resp_body), @max_error_body_bytes))

        is_map(resp_body) ->
          Jason.encode!(resp_body)

        true ->
          ""
      end
    end
  end

  defp sanitize_secret(text, secret)
       when is_binary(text) and is_binary(secret) and secret != "" do
    :binary.replace(text, secret, "[REDACTED]", [:global])
  end

  defp sanitize_secret(text, _secret), do: text

  defp kind_for_status(429), do: :rate_limit
  defp kind_for_status(status) when status in [401, 403], do: :auth
  defp kind_for_status(status) when status >= 500 and status <= 599, do: :server
  defp kind_for_status(_status), do: :bad_request

  defp body_to_string(body) when is_binary(body), do: body
  defp body_to_string(body), do: Jason.encode!(body)

  defp reason_to_string(reason) when is_binary(reason), do: reason
  defp reason_to_string(reason) when is_exception(reason), do: Exception.message(reason)
  defp reason_to_string(reason), do: inspect(reason)

  defp get_stream_state(resp, default), do: Map.get(resp.private, @stream_state_key, default)
  defp put_stream_state(resp, state), do: put_in(resp.private[@stream_state_key], state)
end

defmodule IexCode.LLM.OpenAI do
  @moduledoc """
  OpenAI-compatible client supporting GPT-4o, o1, o3-mini, Gemini proxies,
  and function calling with SSE streaming.
  """
  require Logger
  alias IexCode.LLM.StreamClient

  def chat(messages, system_prompt, opts, on_chunk \\ fn _c -> :ok end) do
    api_key = Keyword.get(opts, :api_key, "")
    base_url = Keyword.get(opts, :base_url, "https://api.openai.com/v1")
    model = Keyword.get(opts, :model, "gpt-4o")
    temperature = Keyword.get(opts, :temperature, 0.2)
    tools = Keyword.get(opts, :tools, [])
    stream? = Keyword.get(opts, :stream, true)

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

    formatted_messages =
      [%{"role" => "system", "content" => system_prompt}] ++
        Enum.map(messages, fn
          %{role: "user", content: c} ->
            %{"role" => "user", "content" => c}

          %{role: "assistant", content: c} ->
            %{"role" => "assistant", "content" => c}

          %{role: "tool", content: c, tool_call_id: id} ->
            %{"role" => "tool", "tool_call_id" => id, "content" => c}

          other when is_map(other) ->
            other

          other ->
            %{"role" => "user", "content" => to_string(other)}
        end)

    openai_tools =
      Enum.map(tools, fn t ->
        %{
          "type" => "function",
          "function" => %{
            "name" => t.name,
            "description" => t.description,
            "parameters" => t.parameters
          }
        }
      end)

    body =
      %{
        "model" => model,
        "messages" => formatted_messages,
        "temperature" => temperature
      }
      |> then(fn map ->
        if openai_tools != [] do
          Map.put(map, "tools", openai_tools)
        else
          map
        end
      end)

    url = String.trim_trailing(base_url, "/") <> "/chat/completions"

    if api_key == "" or api_key == nil do
      mock_response(messages, on_chunk)
    else
      if stream? do
        request_opts = [
          provider: "openai",
          url: url,
          headers: headers,
          body: body,
          receive_timeout: Keyword.get(opts, :receive_timeout, 25_000)
        ]

        case StreamClient.stream(request_opts, on_chunk) do
          {:ok, %{text: text, tool_calls: tool_calls, raw: raw}} ->
            {:ok, %{text: text, tool_calls: tool_calls, raw: raw}}

          {:error, %{status: status, body: body_resp}} ->
            {:error, "OpenAI API returned status #{status}: #{inspect(body_resp)}"}

          {:error, reason} ->
            {:error, "OpenAI API request failed: #{inspect(reason)}"}
        end
      else
        case Req.post(url,
               json: body,
               headers: headers,
               receive_timeout: Keyword.get(opts, :receive_timeout, 25_000)
             ) do
          {:ok, %{status: 200, body: %{"choices" => [choice | _]} = resp}} ->
            msg = choice["message"] || %{}
            text = msg["content"] || ""

            tool_calls =
              (msg["tool_calls"] || [])
              |> Enum.map(fn tc ->
                args =
                  case Jason.decode(tc["function"]["arguments"] || "{}") do
                    {:ok, decoded} -> decoded
                    _ -> %{}
                  end

                %{
                  id: tc["id"],
                  name: tc["function"]["name"],
                  args: args
                }
              end)

            on_chunk.(text)
            {:ok, %{text: text, tool_calls: tool_calls, raw: resp}}

          {:ok, %{status: status, body: body_resp}} ->
            {:error, "OpenAI API returned status #{status}: #{inspect(body_resp)}"}

          {:error, reason} ->
            {:error, "OpenAI API request failed: #{inspect(reason)}"}
        end
      end
    end
  end

  defp mock_response(messages, on_chunk) do
    last_msg = List.last(messages)
    content = if is_map(last_msg), do: Map.get(last_msg, :content, ""), else: to_string(last_msg)

    response =
      """
      I am running in local mode (OpenAI API key not configured in settings).

      Processing:
      > #{String.slice(content, 0, 120)}...
      """

    on_chunk.(response)
    {:ok, %{text: response, tool_calls: [], raw: %{}}}
  end
end

defmodule IexCode.LLM.Anthropic do
  @moduledoc """
  Anthropic API client supporting streaming messages, tool use, and custom endpoints.
  """
  require Logger
  alias IexCode.LLM.StreamClient

  def chat(messages, system_prompt, opts, on_chunk \\ fn _c -> :ok end) do
    api_key = Keyword.get(opts, :api_key, "")
    base_url = Keyword.get(opts, :base_url, "https://api.anthropic.com")
    model = Keyword.get(opts, :model, "claude-3-7-sonnet")
    temperature = Keyword.get(opts, :temperature, 0.2)
    tools = Keyword.get(opts, :tools, [])
    stream? = Keyword.get(opts, :stream, true)

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]

    formatted_messages =
      Enum.map(messages, fn
        %{role: "user", content: c} ->
          %{"role" => "user", "content" => c}

        %{role: "assistant", content: c} ->
          %{"role" => "assistant", "content" => c}

        %{role: "tool", content: c, tool_call_id: id} ->
          %{
            "role" => "user",
            "content" => [
              %{
                "type" => "tool_result",
                "tool_use_id" => id,
                "content" => c
              }
            ]
          }

        other when is_map(other) ->
          other

        other ->
          %{"role" => "user", "content" => to_string(other)}
      end)

    anthropic_tools =
      Enum.map(tools, fn t ->
        %{
          "name" => t.name,
          "description" => t.description,
          "input_schema" => t.parameters
        }
      end)

    body =
      %{
        "model" => model,
        "max_tokens" => 4096,
        "temperature" => temperature,
        "messages" => formatted_messages,
        "system" => system_prompt
      }
      |> then(fn map ->
        if anthropic_tools != [] do
          Map.put(map, "tools", anthropic_tools)
        else
          map
        end
      end)

    url = String.trim_trailing(base_url, "/") <> "/v1/messages"

    if api_key == "" or api_key == nil do
      # Mock response if no API key is provided
      mock_response(messages, on_chunk)
    else
      if stream? do
        request_opts = [
          provider: "anthropic",
          url: url,
          headers: headers,
          body: body,
          receive_timeout: Keyword.get(opts, :receive_timeout, 25_000)
        ]

        case StreamClient.stream(request_opts, on_chunk) do
          {:ok, %{text: text, tool_calls: tool_calls, raw: raw}} ->
            {:ok, %{text: text, tool_calls: tool_calls, raw: raw}}

          {:error, %{status: status, body: body_resp}} ->
            {:error, "Anthropic API returned status #{status}: #{inspect(body_resp)}"}

          {:error, reason} ->
            {:error, "Anthropic API request failed: #{inspect(reason)}"}
        end
      else
        case Req.post(url,
               json: body,
               headers: headers,
               receive_timeout: Keyword.get(opts, :receive_timeout, 25_000)
             ) do
          {:ok, %{status: 200, body: %{"content" => content_blocks} = resp}} ->
            text_blocks =
              content_blocks
              |> Enum.filter(&(&1["type"] == "text"))
              |> Enum.map(& &1["text"])
              |> Enum.join("")

            tool_calls =
              content_blocks
              |> Enum.filter(&(&1["type"] == "tool_use"))
              |> Enum.map(fn b ->
                %{
                  id: b["id"],
                  name: b["name"],
                  args: b["input"] || %{}
                }
              end)

            on_chunk.(text_blocks)
            {:ok, %{text: text_blocks, tool_calls: tool_calls, raw: resp}}

          {:ok, %{status: status, body: body_resp}} ->
            {:error, "Anthropic API returned status #{status}: #{inspect(body_resp)}"}

          {:error, reason} ->
            {:error, "Anthropic API request failed: #{inspect(reason)}"}
        end
      end
    end
  end

  defp mock_response(messages, on_chunk) do
    last_msg = List.last(messages)
    content = if is_map(last_msg), do: Map.get(last_msg, :content, ""), else: to_string(last_msg)

    response =
      """
      I am running in local mode (API key not configured in settings).

      Received request:
      > #{String.slice(content, 0, 120)}...

      * OTP Asynchronous Actor Engine is active.
      * Swarm Mode is ready.
      * All file tools (`read_file`, `write_file`, `grep_search`, `run_command`) are available.
      """

    on_chunk.(response)
    {:ok, %{text: response, tool_calls: [], raw: %{}}}
  end
end

defmodule IexCode.LLM.SSEParser do
  @moduledoc """
  Parser for Server-Sent Events (SSE) supporting both OpenAI-compatible
  and Anthropic Claude streaming formats.
  Handles line framing, delta extraction, tool call chunks, and stop signals.
  """
  require Logger

  defstruct event: nil, data_lines: [], line_buffer: ""

  @type t :: %__MODULE__{
          event: String.t() | nil,
          data_lines: [String.t()],
          line_buffer: String.t()
        }

  @type sse_event :: %{
          event: String.t(),
          data: String.t()
        }

  @type delta_result ::
          {:delta,
           %{
             text: String.t(),
             tool_calls: [map()],
             reasoning: String.t()
           }}
          | {:done, reason :: atom() | String.t()}
          | {:done, reason :: atom() | String.t(), final_delta :: map()}
          | {:error, term()}
          | :ignore

  @doc """
  Creates a new SSE parser state.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Consumes a UTF-8 text chunk, frames complete SSE lines and events,
  and returns `{[sse_event], new_state}`.
  """
  @spec parse(t(), String.t()) :: {[sse_event()], t()}
  def parse(%__MODULE__{} = state, text_chunk) do
    combined = state.line_buffer <> (text_chunk || "")
    lines = String.split(combined, ~r/\r?\n/)
    {complete_lines, [incomplete_line]} = Enum.split(lines, -1)

    {events, final_state} =
      Enum.reduce(
        complete_lines,
        {[], %{state | line_buffer: incomplete_line}},
        fn line, {ev_acc, st} ->
          process_line(line, ev_acc, st)
        end
      )

    {events, final_state}
  end

  @doc """
  Parses a raw chunk directly (convenience wrapper).
  """
  @spec parse_chunk(String.t()) :: {:ok, [sse_event()]} | {:done} | {:error, term()}
  def parse_chunk(chunk) do
    {events, _st} = parse(new(), chunk)
    {:ok, events}
  end

  @doc """
  Translates a generic SSE event into a structured delta result based on provider format.
  Provider can be "openai", "anthropic", or "gemini".
  """
  @spec parse_event(sse_event(), String.t()) :: delta_result()
  def parse_event(%{data: "[DONE]"}, _provider), do: {:done, :stop}
  def parse_event(%{event: "message_stop"}, "anthropic"), do: {:done, :stop}

  # --- OpenAI Provider Parsing ---
  def parse_event(%{data: json_str}, "openai") do
    trimmed = String.trim(json_str)

    if trimmed == "[DONE]" do
      {:done, :stop}
    else
      case Jason.decode(trimmed) do
        {:ok, %{"choices" => [%{"delta" => delta} = choice | _]}} ->
          finish_reason = choice["finish_reason"]
          tool_calls = delta["tool_calls"] || []
          text = delta["content"] || ""
          reasoning = delta["reasoning_content"] || delta["reasoning"] || ""

          delta_map = %{text: text, tool_calls: tool_calls, reasoning: reasoning}

          if finish_reason != nil and finish_reason != "" do
            {:done, finish_reason, delta_map}
          else
            {:delta, delta_map}
          end

        {:ok, %{"error" => error_map}} ->
          {:error, error_map}

        {:ok, _other} ->
          :ignore

        {:error, err} ->
          {:error, err}
      end
    end
  end

  # --- Anthropic Provider Parsing ---
  def parse_event(%{event: "content_block_delta", data: json_str}, "anthropic") do
    case Jason.decode(String.trim(json_str)) do
      {:ok, %{"delta" => %{"type" => "text_delta", "text" => text}}} ->
        {:delta, %{text: text, tool_calls: [], reasoning: ""}}

      {:ok, %{"delta" => %{"type" => "thinking_delta", "thinking" => thinking}}} ->
        {:delta, %{text: "", tool_calls: [], reasoning: thinking}}

      {:ok, %{"index" => idx, "delta" => %{"type" => "input_json_delta", "partial_json" => pj}}} ->
        {:delta,
         %{
           text: "",
           tool_calls: [%{"index" => idx, "function" => %{"arguments" => pj}}],
           reasoning: ""
         }}

      {:ok, _} ->
        :ignore

      {:error, err} ->
        {:error, err}
    end
  end

  def parse_event(%{event: "content_block_start", data: json_str}, "anthropic") do
    case Jason.decode(String.trim(json_str)) do
      {:ok,
       %{"index" => idx, "content_block" => %{"type" => "tool_use", "id" => id, "name" => name}}} ->
        {:delta,
         %{
           text: "",
           tool_calls: [
             %{
               "index" => idx,
               "id" => id,
               "function" => %{"name" => name, "arguments" => ""}
             }
           ],
           reasoning: ""
         }}

      _ ->
        :ignore
    end
  end

  def parse_event(%{event: "message_delta", data: json_str}, "anthropic") do
    case Jason.decode(String.trim(json_str)) do
      {:ok, %{"delta" => %{"stop_reason" => stop_reason}}} ->
        {:done, stop_reason}

      _ ->
        :ignore
    end
  end

  def parse_event(%{event: "error", data: json_str}, "anthropic") do
    case Jason.decode(String.trim(json_str)) do
      {:ok, %{"error" => err}} -> {:error, err}
      _ -> {:error, json_str}
    end
  end

  def parse_event(_event, _provider), do: :ignore

  # --- Internal SSE Line Processors ---

  defp process_line("", ev_acc, %{event: event, data_lines: data_lines} = st)
       when data_lines != [] or event != nil do
    data_str = data_lines |> Enum.reverse() |> Enum.join("\n")
    event_type = event || "message"
    ev = %{event: event_type, data: data_str}
    {ev_acc ++ [ev], %{st | event: nil, data_lines: []}}
  end

  defp process_line("", ev_acc, st), do: {ev_acc, st}

  defp process_line("event: " <> event_name, ev_acc, st) do
    {ev_acc, %{st | event: String.trim(event_name)}}
  end

  defp process_line("data: " <> data_content, ev_acc, %{data_lines: lines} = st) do
    {ev_acc, %{st | data_lines: [data_content | lines]}}
  end

  defp process_line(":" <> _comment, ev_acc, st), do: {ev_acc, st}
  defp process_line(_other, ev_acc, st), do: {ev_acc, st}
end

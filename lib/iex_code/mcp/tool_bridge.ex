defmodule IexCode.MCP.ToolBridge do
  @moduledoc """
  Bridges MCP server tools into agent tool definitions named
  `mcp__<server>__<tool>`, propagating MCP tool errors (`isError: true`)
  and bounding oversized outputs with clean UTF-8 truncation.
  """

  alias IexCode.MCP.Manager

  @prefix "mcp__"
  @max_output_bytes 256_000

  @doc "Maximum rendered output size in bytes before UTF-8 safe truncation."
  @spec max_output_bytes() :: pos_integer()
  def max_output_bytes, do: @max_output_bytes

  @doc "Builds tool definitions for every connected server's tools."
  @spec definitions(GenServer.server()) :: [map()]
  def definitions(server \\ Manager) do
    for name <- Manager.list_servers(server),
        {:ok, tools} <- [Manager.list_tools(server, name)],
        tool <- tools do
      %{
        name: tool_name(name, tool["name"]),
        description: "MCP #{name}: #{tool["description"] || tool["name"]}",
        parameters: tool["inputSchema"] || %{"type" => "object"}
      }
    end
  end

  @doc "Executes a bridged `mcp__server__tool` call."
  @spec execute(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def execute(name, args) when is_map(args), do: do_execute(Manager, name, args, [])
  def execute(_name, _args), do: {:error, :mcp_bad_tool_name}

  @spec execute(GenServer.server() | String.t(), String.t() | map(), map() | keyword()) ::
          {:ok, term()} | {:error, term()}
  def execute(name, args, opts) when is_binary(name) and is_map(args) and is_list(opts) do
    do_execute(Manager, name, args, opts)
  end

  def execute(server, name, args) do
    do_execute(server, name, args, [])
  end

  @spec execute(GenServer.server(), String.t(), map(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def execute(server, name, args, opts) do
    do_execute(server, name, args, opts)
  end

  defp do_execute(server, @prefix <> rest, args, opts) when is_map(args) and is_list(opts) do
    case String.split(rest, "__", parts: 2) do
      [name, tool] when name != "" and tool != "" ->
        call_server(server, name, tool, args, opts)

      _invalid ->
        {:error, :mcp_bad_tool_name}
    end
  end

  defp do_execute(_server, _name, _args, _opts), do: {:error, :mcp_bad_tool_name}

  @doc "Alias wrapper for executing a bridged `mcp__server__tool` call."
  @spec execute_mcp_tool(GenServer.server() | String.t(), String.t() | map(), map() | keyword()) ::
          {:ok, term()} | {:error, term()}
  def execute_mcp_tool(name, args) when is_binary(name) and is_map(args) do
    execute(Manager, name, args, [])
  end

  def execute_mcp_tool(server, name, args) when is_binary(name) and is_map(args) do
    execute(server, name, args, [])
  end

  @doc "Splits a bridged name into `{server, tool}`."
  @spec split(String.t()) :: {:ok, String.t(), String.t()} | {:error, :mcp_bad_tool_name}
  def split(@prefix <> rest) do
    case String.split(rest, "__", parts: 2) do
      [name, tool] when name != "" and tool != "" -> {:ok, name, tool}
      _invalid -> {:error, :mcp_bad_tool_name}
    end
  end

  def split(_name), do: {:error, :mcp_bad_tool_name}

  defp tool_name(server, tool), do: @prefix <> server <> "__" <> tool

  defp call_server(server, name, tool, args, opts) do
    call_opts = extract_call_opts(args, opts)
    max_bytes = normalize_max_bytes(Keyword.get(opts, :max_output_bytes, @max_output_bytes))
    clean_args = Map.drop(args, ["__workspace_lock_identity__", "__requested_timeout_ms__"])

    case Manager.call_tool(server, name, tool, clean_args, call_opts) do
      {:ok, result} when is_map(result) ->
        format_tool_result(result, max_bytes)

      {:ok, result} when is_binary(result) ->
        {:ok, truncate_output(result, max_bytes)}

      {:ok, other} ->
        {:ok, other}

      {:error, _reason} = error ->
        error
    end
  end

  defp format_tool_result(result, max_bytes) do
    cond do
      error_result?(result) ->
        rendered =
          result
          |> extract_error_content()
          |> ensure_string()
          |> truncate_output(max_bytes)

        {:error, {:mcp_tool_error, rendered}}

      Map.has_key?(result, "content") ->
        {:ok, render_and_bound(Map.get(result, "content"), max_bytes)}

      Map.has_key?(result, :content) ->
        {:ok, render_and_bound(Map.get(result, :content), max_bytes)}

      true ->
        {:ok, bound_arbitrary_result(result, max_bytes)}
    end
  end

  defp error_result?(result) when is_map(result) do
    Map.get(result, "isError") === true or Map.get(result, :isError) === true
  end

  defp extract_error_content(result) do
    cond do
      Map.has_key?(result, "content") ->
        render_content(Map.get(result, "content"))

      Map.has_key?(result, :content) ->
        render_content(Map.get(result, :content))

      is_binary(Map.get(result, "message")) ->
        Map.get(result, "message")

      is_binary(Map.get(result, :message)) ->
        Map.get(result, :message)

      true ->
        result
        |> Map.drop(["isError", :isError])
        |> Jason.encode!()
    end
  end

  defp render_and_bound(content, max_bytes) do
    case render_content(content) do
      text when is_binary(text) -> truncate_output(text, max_bytes)
      other -> bound_arbitrary_result(other, max_bytes)
    end
  end

  defp bound_arbitrary_result(value, max_bytes) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) > max_bytes ->
        truncate_output(encoded, max_bytes)

      _ ->
        value
    end
  end

  defp render_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{type: "text", text: text} when is_binary(text) -> text
      %{} = part -> Jason.encode!(part)
      part -> to_string(part)
    end)
    |> Enum.join("\n")
  end

  defp render_content(content), do: content

  defp ensure_string(value) when is_binary(value), do: value
  defp ensure_string(value), do: Jason.encode!(value)

  @doc false
  @spec truncate_output(String.t(), pos_integer()) :: String.t()
  def truncate_output(text, max_bytes \\ @max_output_bytes) when is_binary(text) do
    sanitized = ensure_valid_utf8(text)
    original_bytes = byte_size(sanitized)

    if original_bytes <= max_bytes do
      sanitized
    else
      notice =
        "\n...[truncated MCP output at #{max_bytes} bytes; original #{original_bytes} bytes]"

      notice_bytes = byte_size(notice)

      if max_bytes > notice_bytes do
        prefix = valid_utf8_prefix(sanitized, max_bytes - notice_bytes)
        prefix <> notice
      else
        valid_utf8_prefix(sanitized, max_bytes)
      end
    end
  end

  defp valid_utf8_prefix(binary, budget) when byte_size(binary) <= budget, do: binary
  defp valid_utf8_prefix(_binary, budget) when budget <= 0, do: ""

  defp valid_utf8_prefix(binary, budget) do
    Enum.find_value(0..min(3, budget), fn trim ->
      candidate = binary_part(binary, 0, budget - trim)
      if String.valid?(candidate), do: candidate
    end) || ""
  end

  defp ensure_valid_utf8(binary) do
    if String.valid?(binary) do
      binary
    else
      binary
      |> String.chunk(:valid)
      |> Enum.map_join(fn chunk ->
        if String.valid?(chunk), do: chunk, else: ""
      end)
    end
  end

  defp extract_call_opts(args, opts) do
    call_opts = Keyword.drop(opts, [:max_output_bytes])

    case Map.get(args, "__requested_timeout_ms__") do
      ms when is_integer(ms) and ms > 0 -> Keyword.put_new(call_opts, :timeout_ms, ms)
      _ -> call_opts
    end
  end

  defp normalize_max_bytes(bytes) when is_integer(bytes) and bytes > 0, do: bytes
  defp normalize_max_bytes(_other), do: @max_output_bytes
end

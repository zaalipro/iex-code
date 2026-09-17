defmodule IexCode.MCP.ToolBridge do
  @moduledoc """
  Bridges MCP server tools into agent tool definitions named
  `mcp__<server>__<tool>`.
  """

  alias IexCode.MCP.Manager

  @prefix "mcp__"

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
  @spec execute(GenServer.server(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def execute(server \\ Manager, name, args)

  def execute(server, @prefix <> rest, args) when is_map(args) do
    case String.split(rest, "__", parts: 2) do
      [name, tool] when name != "" and tool != "" ->
        call_server(server, name, tool, args)

      _invalid ->
        {:error, :mcp_bad_tool_name}
    end
  end

  def execute(_server, _name, _args), do: {:error, :mcp_bad_tool_name}

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

  defp call_server(server, name, tool, args) do
    args = Map.drop(args, ["__workspace_lock_identity__", "__requested_timeout_ms__"])

    case Manager.call_tool(server, name, tool, args) do
      {:ok, %{"content" => content}} -> {:ok, render_content(content)}
      {:ok, other} -> {:ok, other}
      {:error, _reason} = error -> error
    end
  end

  defp render_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      %{} = part -> Jason.encode!(part)
      part -> to_string(part)
    end)
    |> Enum.join("\n")
  end

  defp render_content(content), do: content
end

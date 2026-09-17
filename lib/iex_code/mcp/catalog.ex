defmodule IexCode.MCP.Catalog do
  @moduledoc """
  Loads MCP server catalogs: name -> stdio command spec.

      {
        "servers": {
          "files": {"command": "npx", "args": ["-y", "@mcp/files"], "env": {}}
        }
      }
  """

  @type server_spec :: %{
          command: String.t(),
          args: [String.t()],
          env: %{String.t() => String.t()}
        }

  @doc "Loads a catalog file into validated server specs."
  @spec from_file(String.t()) :: {:ok, %{String.t() => server_spec()}} | {:error, term()}
  def from_file(path) when is_binary(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents),
         {:ok, catalog} <- from_map(decoded) do
      {:ok, catalog}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:mcp_catalog_json, path, error}}
      {:error, reason} -> {:error, {:mcp_catalog, path, reason}}
    end
  end

  @doc "Validates a decoded catalog map."
  @spec from_map(map()) :: {:ok, %{String.t() => server_spec()}} | {:error, term()}
  def from_map(%{"servers" => servers}) when is_map(servers) do
    Enum.reduce_while(servers, {:ok, %{}}, fn {name, spec}, {:ok, acc} ->
      case server_spec(name, spec) do
        {:ok, validated} -> {:cont, {:ok, Map.put(acc, name, validated)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def from_map(_decoded), do: {:error, :mcp_catalog_shape}

  defp server_spec(name, %{"command" => command} = spec)
       when is_binary(name) and is_binary(command) do
    args = Map.get(spec, "args", [])
    env = Map.get(spec, "env", %{})

    cond do
      String.trim(command) == "" ->
        {:error, {:mcp_server_field, name, "command"}}

      not (is_list(args) and Enum.all?(args, &is_binary/1)) ->
        {:error, {:mcp_server_field, name, "args"}}

      not (is_map(env) and Enum.all?(env, fn {k, v} -> is_binary(k) and is_binary(v) end)) ->
        {:error, {:mcp_server_field, name, "env"}}

      true ->
        {:ok, %{command: command, args: args, env: env}}
    end
  end

  defp server_spec(name, _spec), do: {:error, {:mcp_server_field, name, "command"}}
end

defmodule IexCode.Sandbox.Policy do
  @moduledoc """
  Filesystem/network policy for sandboxed command execution.

  `reads`/`writes` are absolute path prefixes. `network` is `:allow` or
  `:deny`. `strict` fails closed when no sandbox backend exists instead of
  running unconfined.
  """

  @enforce_keys []
  defstruct reads: ["/"], writes: [], network: :deny, strict: true

  @type t :: %__MODULE__{
          reads: [String.t()],
          writes: [String.t()],
          network: :allow | :deny,
          strict: boolean()
        }

  @doc "Builds a policy from a string-keyed map (tool args, settings)."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(params) when is_map(params) do
    with {:ok, reads} <- prefixes(params, "reads", ["/"]),
         {:ok, writes} <- prefixes(params, "writes", []),
         {:ok, network} <- network(Map.get(params, "network", "deny")),
         {:ok, strict} <- strict(Map.get(params, "strict", true)) do
      {:ok, %__MODULE__{reads: reads, writes: writes, network: network, strict: strict}}
    end
  end

  def from_map(_params), do: {:error, :sandbox_policy_shape}

  @doc "Workspace-default policy: read the root, write it, no network."
  @spec for_workdir(String.t()) :: t()
  def for_workdir(workdir) when is_binary(workdir) do
    %__MODULE__{reads: ["/", workdir], writes: [workdir], network: :deny, strict: true}
  end

  @doc "True when `path` is under a read prefix (writes imply reads)."
  @spec allows_read?(t(), String.t()) :: boolean()
  def allows_read?(%__MODULE__{} = policy, path) when is_binary(path) do
    under_prefix?(policy.reads ++ policy.writes, path)
  end

  @doc "True when `path` is under a write prefix."
  @spec allows_write?(t(), String.t()) :: boolean()
  def allows_write?(%__MODULE__{} = policy, path) when is_binary(path) do
    under_prefix?(policy.writes, path)
  end

  defp prefixes(params, key, default) do
    case Map.get(params, key, default) do
      values when is_list(values) ->
        if Enum.all?(values, &is_binary/1),
          do: {:ok, values},
          else: {:error, {:sandbox_policy_field, key}}

      _invalid ->
        {:error, {:sandbox_policy_field, key}}
    end
  end

  defp network("allow"), do: {:ok, :allow}
  defp network("deny"), do: {:ok, :deny}
  defp network(:allow), do: {:ok, :allow}
  defp network(:deny), do: {:ok, :deny}
  defp network(_invalid), do: {:error, {:sandbox_policy_field, "network"}}

  defp strict(value) when is_boolean(value), do: {:ok, value}
  defp strict(_invalid), do: {:error, {:sandbox_policy_field, "strict"}}

  defp under_prefix?(prefixes, path) do
    expanded = Path.expand(path)

    Enum.any?(prefixes, fn prefix ->
      suffix = if String.ends_with?(prefix, "/"), do: prefix, else: prefix <> "/"
      expanded == prefix or String.starts_with?(expanded, suffix)
    end)
  end
end

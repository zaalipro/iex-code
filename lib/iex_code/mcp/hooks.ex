defmodule IexCode.MCP.Hooks do
  @moduledoc """
  Lifecycle hooks: session_start, pre_model, post_model, pre_tool,
  post_tool, session_end.

  Config maps event names to handler lists. A handler is either
  `{:mfa, {module, function, extra_args}}` (called as
  `apply(m, f, [payload | extra_args])`) or `{:shell, command}` (run with
  the JSON payload at `$HOOK_PAYLOAD_FILE`, 10s timeout).

  Handler results are collected in order. In `:gate` mode (used for
  pre_tool), a `{:deny, reason}` result short-circuits to denial.
  """

  @events ~w(session_start pre_model post_model pre_tool post_tool session_end)
  @shell_timeout_ms 10_000

  @type event :: String.t()
  @type handler :: {:mfa, {module(), atom(), list()}} | {:shell, String.t()}
  @type config :: %{optional(event()) => [handler()]}

  @doc "Supported hook event names."
  @spec events() :: [event()]
  def events, do: @events

  @doc "Runs all handlers for `event`, collecting `{:ok, result}` / `{:error, reason}`."
  @spec dispatch(event(), map(), config()) :: [{:ok, term()} | {:error, term()}]
  def dispatch(event, payload, config)
      when is_binary(event) and is_map(payload) and is_map(config) do
    config
    |> Map.get(event, [])
    |> Enum.map(&run_handler(&1, payload))
  end

  @doc "Gating dispatch for pre_tool: `:ok` or `{:deny, reason}`."
  @spec gate(event(), map(), config()) :: :ok | {:deny, String.t()}
  def gate(event, payload, config) do
    config
    |> Map.get(event, [])
    |> Enum.reduce_while(:ok, fn handler, :ok ->
      case run_handler(handler, payload) do
        {:ok, {:deny, reason}} -> {:halt, {:deny, to_string(reason)}}
        {:ok, %{"decision" => "deny", "reason" => reason}} -> {:halt, {:deny, to_string(reason)}}
        {:ok, _allowed} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:deny, "hook failed: #{inspect(reason)}"}}
      end
    end)
  end

  defp run_handler({:mfa, {module, function, extra_args}}, payload)
       when is_atom(module) and is_atom(function) and is_list(extra_args) do
    {:ok, apply(module, function, [payload | extra_args])}
  rescue
    exception -> {:error, {:hook_crashed, Exception.message(exception)}}
  end

  defp run_handler({:shell, command}, payload) when is_binary(command) do
    with {:ok, input} <- Jason.encode(payload),
         {:ok, path} <- write_payload(input) do
      shell_task =
        Task.async(fn ->
          System.cmd("sh", ["-c", command], env: [{"HOOK_PAYLOAD_FILE", path}])
        end)

      result =
        case Task.yield(shell_task, @shell_timeout_ms) || Task.shutdown(shell_task, :brutal_kill) do
          {:ok, {output, 0}} -> {:ok, parse_shell_output(output)}
          {:ok, {output, code}} -> {:error, {:hook_exit, code, String.slice(output, 0, 1_000)}}
          {:exit, reason} -> {:error, {:hook_crashed, reason}}
          nil -> {:error, :hook_timeout}
        end

      File.rm(path)
      result
    end
  end

  defp run_handler(_handler, _payload), do: {:error, :hook_bad_handler}

  defp write_payload(input) do
    path = Path.join(System.tmp_dir!(), "iex-hook-#{System.unique_integer([:positive])}.json")

    case File.write(path, input) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:hook_payload, reason}}
    end
  end

  defp parse_shell_output(output) do
    case Jason.decode(String.trim(output)) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{"output" => String.slice(output, 0, 2_000)}
    end
  end
end

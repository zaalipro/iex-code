defmodule IexCode.Sandbox.Manager do
  @moduledoc """
  Runs commands inside OS sandboxes with policy gating and approvals.

  Approvals are short-lived grants keyed by command fingerprint
  (sha256 of the argv join). A policy with `strict: true` (default)
  fails closed when no backend exists; `strict: false` runs unconfined
  with a warning result flag.
  """

  use GenServer
  require Logger

  alias IexCode.Sandbox.{Backend, Policy}
  alias IexCode.Tools.ProcessGroupRunner

  @default_timeout_ms 30_000
  @default_approval_ttl_ms 300_000
  @default_max_approvals 1_024
  @max_output_bytes 256_000

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Grants one fingerprint until now + ttl."
  @spec approve(GenServer.server(), String.t(), keyword()) :: {:ok, map()}
  def approve(server \\ __MODULE__, command, opts \\ []) when is_binary(command) do
    ttl = Keyword.get(opts, :ttl_ms, @default_approval_ttl_ms)
    GenServer.call(server, {:approve, command, ttl})
  end

  @doc "True when a live approval covers `command`."
  @spec approved?(GenServer.server(), String.t()) :: boolean()
  def approved?(server \\ __MODULE__, command) when is_binary(command) do
    GenServer.call(server, {:approved?, command})
  end

  @doc """
  Runs argv under `policy`. Options: `:workdir`, `:timeout_ms`,
  `:require_approval` (default false), `:backend` (default detected).
  """
  @spec run([String.t()], Policy.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(argv, policy \\ %Policy{}, opts \\ [])

  def run([_cmd | _rest] = argv, %Policy{} = policy, opts) when is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    backend = Keyword.get(opts, :backend, Backend.detect())
    workdir = Keyword.get(opts, :workdir, File.cwd!())
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    env = Keyword.get(opts, :env, %{})

    with :ok <- Policy.validate(policy),
         :ok <- check_approval(server, argv, opts),
         {:ok, wrapped} <- confine(backend, argv, policy) do
      execute(wrapped, workdir, timeout, backend, env)
    end
  end

  def run(_argv, _policy, _opts), do: {:error, :sandbox_empty_command}

  @doc "Fingerprints a command line for approvals."
  @spec fingerprint([String.t()] | String.t()) :: String.t()
  def fingerprint(argv) when is_list(argv), do: fingerprint(Enum.join(argv, "\u0000"))

  def fingerprint(command) when is_binary(command) do
    :crypto.hash(:sha256, command) |> Base.encode16(case: :lower)
  end

  @impl true
  def init(opts) do
    max_approvals =
      normalize_max_approvals(Keyword.get(opts, :max_approvals, @default_max_approvals))

    {:ok, %{approvals: %{}, max_approvals: max_approvals, next_seq: 1}}
  end

  @impl true
  def handle_call({:approve, command, ttl}, _from, state) do
    now = now_ms()
    fp = fingerprint(command)
    expires_at = now + max(ttl, 0)
    grant = %{fingerprint: fp, expires_at: expires_at}

    pruned = prune_expired(state.approvals, now)

    {approvals, next_seq} =
      if expires_at > now do
        cleaned =
          pruned
          |> Map.delete(fp)
          |> evict_oldest_if_full(state.max_approvals)

        stored = Map.put(grant, :granted_seq, state.next_seq)
        {Map.put(cleaned, fp, stored), state.next_seq + 1}
      else
        {Map.delete(pruned, fp), state.next_seq}
      end

    {:reply, {:ok, grant}, %{state | approvals: approvals, next_seq: next_seq}}
  end

  def handle_call({:approved?, command}, _from, state) do
    now = now_ms()
    approvals = prune_expired(state.approvals, now)
    fp = fingerprint(command)

    approved? =
      case Map.get(approvals, fp) do
        %{expires_at: expires_at} when is_integer(expires_at) -> expires_at > now
        _missing -> false
      end

    {:reply, approved?, %{state | approvals: approvals}}
  end

  defp check_approval(server, argv, opts) do
    if Keyword.get(opts, :require_approval, false) do
      if approved?(server, Enum.join(argv, "\u0000")),
        do: :ok,
        else: {:error, :sandbox_approval_required}
    else
      :ok
    end
  end

  defp confine(:none, _argv, %Policy{strict: true}), do: {:error, :no_sandbox_backend}

  defp confine(:none, argv, %Policy{strict: false} = policy) do
    Logger.warning("sandbox: no backend, running unconfined")
    {:ok, {:unconfined, argv, policy}}
  end

  defp confine(:sandbox_exec, argv, policy) do
    path =
      Path.join(System.tmp_dir!(), "iex-sandbox-#{System.unique_integer([:positive])}.sb")

    with :ok <- File.write(path, Backend.seatbelt_profile(policy)),
         {:ok, wrapped} <- Backend.wrap(:sandbox_exec, argv, policy, profile_path: path) do
      {:ok, {:confined, wrapped, path}}
    else
      {:error, _reason} = error ->
        File.rm(path)
        error
    end
  end

  defp confine(backend, argv, policy) do
    case Backend.wrap(backend, argv, policy, []) do
      {:ok, wrapped} -> {:ok, {:confined, wrapped, nil}}
      {:error, _reason} = error -> error
    end
  end

  defp execute({:unconfined, [cmd | args], _policy}, workdir, timeout, _backend, env) do
    run_cmd(cmd, args, workdir, timeout, :unconfined, env)
  end

  defp execute({:confined, [cmd | args], profile_path}, workdir, timeout, backend, env) do
    try do
      run_cmd(cmd, args, workdir, timeout, backend, env)
    after
      if is_binary(profile_path), do: File.rm(profile_path)
    end
  end

  defp run_cmd(cmd, args, workdir, timeout, backend, env) do
    executable = resolve_executable(cmd)

    cond do
      is_nil(executable) ->
        {:error, {:sandbox_no_command, cmd}}

      Enum.any?([executable | args], &String.contains?(&1, <<0>>)) ->
        {:error, :sandbox_invalid_argument}

      true ->
        shell_cmd = "exec " <> Enum.map_join([executable | args], " ", &shell_quote/1)

        runner_opts = [
          cd: workdir,
          env: if(is_map(env), do: env, else: %{}),
          timeout_ms: timeout,
          max_output_bytes: @max_output_bytes
        ]

        case ProcessGroupRunner.run(shell_cmd, runner_opts) do
          {:ok, %{exit_code: exit_code, output: output}} ->
            {:ok,
             %{
               exit_code: exit_code,
               output: String.slice(output || "", 0, @max_output_bytes),
               backend: backend,
               confined: backend != :unconfined
             }}

          {:timeout, _info} ->
            {:error, :sandbox_timeout}

          {:error, reason} ->
            {:error, {:sandbox_crashed, reason}}
        end
    end
  end

  defp resolve_executable(cmd) do
    if String.contains?(cmd, "/") do
      if File.regular?(cmd), do: cmd, else: nil
    else
      System.find_executable(cmd)
    end
  end

  defp shell_quote(arg) when is_binary(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  defp prune_expired(approvals, now) do
    Map.reject(approvals, fn {_fp, grant} ->
      not (is_integer(grant.expires_at) and grant.expires_at > now)
    end)
  end

  defp evict_oldest_if_full(approvals, max_approvals) when map_size(approvals) < max_approvals do
    approvals
  end

  defp evict_oldest_if_full(approvals, max_approvals) do
    excess = map_size(approvals) - max_approvals + 1

    if excess == 1 do
      {oldest_fp, _grant} = Enum.min_by(approvals, fn {_fp, grant} -> grant.granted_seq end)
      Map.delete(approvals, oldest_fp)
    else
      drop_keys =
        approvals
        |> Enum.sort_by(fn {_fp, grant} -> grant.granted_seq end)
        |> Enum.take(excess)
        |> Enum.map(&elem(&1, 0))

      Map.drop(approvals, drop_keys)
    end
  end

  defp normalize_max_approvals(n) when is_integer(n) and n > 0, do: n
  defp normalize_max_approvals(_), do: @default_max_approvals

  defp now_ms, do: System.monotonic_time(:millisecond)
end

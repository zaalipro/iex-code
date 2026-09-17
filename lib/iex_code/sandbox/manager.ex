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

  @default_timeout_ms 30_000
  @default_approval_ttl_ms 300_000

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

    with :ok <- check_approval(server, argv, opts),
         {:ok, wrapped} <- confine(backend, argv, policy) do
      execute(wrapped, workdir, timeout, backend)
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
  def init(_opts), do: {:ok, %{approvals: %{}}}

  @impl true
  def handle_call({:approve, command, ttl}, _from, state) do
    grant = %{fingerprint: fingerprint(command), expires_at: now_ms() + max(ttl, 0)}

    {:reply, {:ok, grant},
     %{state | approvals: Map.put(state.approvals, grant.fingerprint, grant)}}
  end

  def handle_call({:approved?, command}, _from, state) do
    case Map.get(state.approvals, fingerprint(command)) do
      %{expires_at: expires_at} ->
        {:reply, is_integer(expires_at) and expires_at > now_ms(), state}

      _missing ->
        {:reply, false, state}
    end
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
    end
  end

  defp confine(backend, argv, policy) do
    case Backend.wrap(backend, argv, policy, []) do
      {:ok, wrapped} -> {:ok, {:confined, wrapped, nil}}
      {:error, _reason} = error -> error
    end
  end

  defp execute({:unconfined, [cmd | args], _policy}, workdir, timeout, _backend) do
    run_cmd(cmd, args, workdir, timeout, :unconfined)
  end

  defp execute({:confined, [cmd | args], profile_path}, workdir, timeout, backend) do
    try do
      run_cmd(cmd, args, workdir, timeout, backend)
    after
      if is_binary(profile_path), do: File.rm(profile_path)
    end
  end

  defp run_cmd(cmd, args, workdir, timeout, backend) do
    executable = if String.contains?(cmd, "/"), do: cmd, else: System.find_executable(cmd)

    if is_nil(executable) do
      {:error, {:sandbox_no_command, cmd}}
    else
      cmd_task =
        Task.async(fn -> System.cmd(executable, args, cd: workdir, stderr_to_stdout: true) end)

      case Task.yield(cmd_task, timeout) || Task.shutdown(cmd_task, :brutal_kill) do
        {:ok, {output, exit_code}} ->
          {:ok,
           %{
             exit_code: exit_code,
             output: String.slice(output || "", 0, 256_000),
             backend: backend,
             confined: backend != :unconfined
           }}

        {:exit, reason} ->
          {:error, {:sandbox_crashed, reason}}

        nil ->
          {:error, :sandbox_timeout}
      end
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end

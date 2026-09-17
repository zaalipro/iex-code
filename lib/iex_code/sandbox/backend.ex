defmodule IexCode.Sandbox.Backend do
  @moduledoc """
  Sandbox backend detection and command wrapping.

  Linux prefers `bwrap` (bubblewrap); macOS uses `sandbox-exec` with a
  generated Seatbelt profile. `detect/0` returns `:bwrap`,
  `:sandbox_exec`, or `:none`.
  """

  alias IexCode.Sandbox.Policy

  @type backend :: :bwrap | :sandbox_exec | :none

  @doc "Detects the best available sandbox backend."
  @spec detect() :: backend()
  def detect do
    cond do
      System.find_executable("bwrap") != nil -> :bwrap
      System.find_executable("sandbox-exec") != nil -> :sandbox_exec
      true -> :none
    end
  end

  @doc "Wraps argv for the backend. sandbox-exec needs a profile file first."
  @spec wrap(backend(), [String.t()], Policy.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def wrap(:bwrap, [_cmd | _rest] = argv, %Policy{} = policy, _opts) do
    {:ok, bwrap_argv(argv, policy)}
  end

  def wrap(_backend, [], _policy, _opts), do: {:error, :sandbox_empty_command}

  def wrap(:sandbox_exec, argv, %Policy{}, opts) do
    case Keyword.fetch(opts, :profile_path) do
      {:ok, path} when is_binary(path) -> {:ok, ["sandbox-exec", "-f", path] ++ argv}
      _missing -> {:error, :sandbox_profile_required}
    end
  end

  def wrap(:none, _argv, _policy, _opts), do: {:error, :no_sandbox_backend}
  def wrap(_backend, _argv, _policy, _opts), do: {:error, :sandbox_bad_backend}

  @doc "Generates a Seatbelt profile for `policy`."
  @spec seatbelt_profile(Policy.t()) :: String.t()
  def seatbelt_profile(%Policy{} = policy) do
    read_rules =
      Enum.map_join(policy.reads, "\n", fn prefix ->
        ~s|  (allow file-read* (subpath "#{escape(prefix)}"))|
      end)

    write_rules =
      Enum.map_join(policy.writes, "\n", fn prefix ->
        ~s|  (allow file-write* (subpath "#{escape(prefix)}"))|
      end)

    network_rules =
      case policy.network do
        :allow -> "  (allow network*)\n"
        :deny -> "  (deny network*)\n"
      end

    """
    (version 1)
    (deny default)
    (allow process-exec (with no-sandbox))
    (allow sysctl-read)
    (allow mach-lookup)
    (allow file-read* (subpath "/usr") (subpath "/bin") (subpath "/private/tmp"))
    #{read_rules}
    #{write_rules}
    #{network_rules}\
    """
  end

  defp bwrap_argv(argv, policy) do
    base = ["bwrap", "--die-with-parent", "--unshare-pid", "--unshare-uts", "--unshare-ipc"]

    base =
      if policy.network == :deny,
        do: base ++ ["--unshare-net"],
        else: base ++ ["--share-net"]

    binds =
      Enum.flat_map(policy.reads, &["--ro-bind", &1, &1]) ++
        Enum.flat_map(policy.writes, &["--bind", &1, &1])

    tmp = ["--tmpfs", "/tmp", "--proc", "/proc", "--dev", "/dev"]

    base ++ binds ++ tmp ++ ["--"] ++ argv
  end

  defp escape(path), do: String.replace(path, "\"", "\\\"")
end

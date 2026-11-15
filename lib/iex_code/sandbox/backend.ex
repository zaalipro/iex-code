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
    with :ok <- Policy.validate(policy) do
      {:ok, bwrap_argv(argv, policy)}
    end
  end

  def wrap(_backend, [], _policy, _opts), do: {:error, :sandbox_empty_command}

  def wrap(:sandbox_exec, argv, %Policy{} = policy, opts) do
    with :ok <- Policy.validate(policy) do
      case Keyword.fetch(opts, :profile_path) do
        {:ok, path} when is_binary(path) -> {:ok, ["sandbox-exec", "-f", path] ++ argv}
        _missing -> {:error, :sandbox_profile_required}
      end
    end
  end

  def wrap(:none, _argv, _policy, _opts), do: {:error, :no_sandbox_backend}
  def wrap(_backend, _argv, _policy, _opts), do: {:error, :sandbox_bad_backend}

  @doc "Generates a Seatbelt profile for `policy`."
  @spec seatbelt_profile(Policy.t()) :: String.t()
  def seatbelt_profile(%Policy{} = policy) do
    read_prefixes = expand_seatbelt_prefixes(policy.reads ++ policy.writes)
    write_prefixes = expand_seatbelt_prefixes(policy.writes)

    read_rules =
      Enum.map_join(read_prefixes, "\n", fn prefix ->
        ~s|  (allow file-read* (subpath "#{escape(prefix)}"))|
      end)

    write_rules =
      Enum.map_join(write_prefixes, "\n", fn prefix ->
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
    (allow process-exec)
    (allow process-fork)
    (allow signal (target same-sandbox))
    (allow sysctl-read)
    (allow mach-lookup)
    (allow file-read-metadata)
    (allow file-map-executable)
    (allow file-read* (literal "/") (subpath "/usr") (subpath "/bin") (subpath "/sbin") (subpath "/System") (subpath "/Library") (subpath "/dev") (subpath "/private/var/db"))
    (allow file-write* (literal "/dev/null") (literal "/dev/zero"))
    #{read_rules}
    #{write_rules}
    #{network_rules}\
    """
  end

  defp expand_seatbelt_prefixes(prefixes) do
    prefixes
    |> Enum.flat_map(&expand_macos_prefix/1)
    |> Enum.uniq()
  end

  defp expand_macos_prefix(prefix) do
    _ = escape(prefix)

    case :os.type() do
      {:unix, :darwin} ->
        case macos_private_alias(prefix) do
          nil -> [prefix]
          ^prefix -> [prefix]
          canonical -> [prefix, canonical]
        end

      _other ->
        [prefix]
    end
  end

  defp macos_private_alias(prefix) do
    cond do
      prefix == "/tmp" or String.starts_with?(prefix, "/tmp/") ->
        "/private" <> prefix

      prefix == "/var" or String.starts_with?(prefix, "/var/") ->
        "/private" <> prefix

      true ->
        nil
    end
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

  defp escape(path) when is_binary(path) do
    if not Policy.valid_prefix?(path) do
      raise ArgumentError, "invalid seatbelt path: #{inspect(path)}"
    end

    path
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end

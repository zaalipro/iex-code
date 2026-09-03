import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/iex_code start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :iex_code, IexCodeWeb.Endpoint, server: true
end

config :iex_code, IexCodeWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  app_support_dir = Path.expand("~/Library/Application Support/IexCode")

  database_path =
    case System.get_env("DATABASE_PATH") do
      nil ->
        File.mkdir_p!(app_support_dir)
        Path.join(app_support_dir, "iex_code.db")

      "" ->
        File.mkdir_p!(app_support_dir)
        Path.join(app_support_dir, "iex_code.db")

      path ->
        File.mkdir_p!(Path.dirname(path))
        path
    end

  config :iex_code, IexCode.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    busy_timeout: 5000,
    journal_mode: :wal

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # If SECRET_KEY_BASE env is missing, check ~/Library/Application Support/IexCode/secret_key_base;
  # if file exists read it, otherwise generate a secure 64-byte random string, write it to file, and use it.
  secret_key_base =
    case System.get_env("SECRET_KEY_BASE") do
      nil ->
        File.mkdir_p!(app_support_dir)
        secret_file = Path.join(app_support_dir, "secret_key_base")
        legacy_secret_file = Path.join(app_support_dir, ".secret_key_base")

        cond do
          File.exists?(secret_file) ->
            File.read!(secret_file) |> String.trim()

          File.exists?(legacy_secret_file) ->
            File.read!(legacy_secret_file) |> String.trim()

          true ->
            key = :crypto.strong_rand_bytes(64) |> Base.encode64(padding: false)
            File.write!(secret_file, key)
            File.chmod(secret_file, 0o600)
            key
        end

      "" ->
        File.mkdir_p!(app_support_dir)
        secret_file = Path.join(app_support_dir, "secret_key_base")
        legacy_secret_file = Path.join(app_support_dir, ".secret_key_base")

        cond do
          File.exists?(secret_file) ->
            File.read!(secret_file) |> String.trim()

          File.exists?(legacy_secret_file) ->
            File.read!(legacy_secret_file) |> String.trim()

          true ->
            key = :crypto.strong_rand_bytes(64) |> Base.encode64(padding: false)
            File.write!(secret_file, key)
            File.chmod(secret_file, 0o600)
            key
        end

      key ->
        key
    end

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")
  scheme = if host in ["localhost", "127.0.0.1"], do: "http", else: "https"
  url_port = if scheme == "https", do: 443, else: port

  # Bind to loopback by default. Set IEX_CODE_BIND (e.g. "0.0.0.0" or
  # "::") to explicitly override.
  bind_ip =
    case System.get_env("IEX_CODE_BIND") do
      nil ->
        {127, 0, 0, 1}

      "" ->
        {127, 0, 0, 1}

      ip ->
        case :inet.parse_address(String.to_charlist(ip)) do
          {:ok, addr} ->
            addr

          {:error, _} ->
            raise """
            environment variable IEX_CODE_BIND is not a valid IP address: #{inspect(ip)}
            For example: 0.0.0.0 or ::
            """
        end
    end

  start_desktop_window = System.get_env("DESKTOP_WINDOW") != "false"
  config :iex_code, start_desktop_window: start_desktop_window

  if start_desktop_window do
    Application.ensure_all_started(:desktop)
  end

  if System.get_env("PHX_SERVER") || start_desktop_window do
    config :iex_code, IexCodeWeb.Endpoint, server: true
  end

  config :iex_code, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :iex_code, IexCodeWeb.Endpoint,
    url: [host: host, port: url_port, scheme: scheme],
    http: [
      # Bind on loopback by default; override with the IEX_CODE_BIND
      # environment variable (see above).
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: bind_ip,
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :iex_code, IexCodeWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :iex_code, IexCodeWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end

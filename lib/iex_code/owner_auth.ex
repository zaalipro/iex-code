defmodule IexCode.OwnerAuth do
  @moduledoc false

  use GenServer

  alias IexCode.OwnerAuth.Credentials

  @default_table :iex_code_owner_auth
  @session_lifetime_ms 8 * 60 * 60 * 1_000
  @bucket_capacity 5
  @refill_interval_ms 12_000
  @digest_bytes 32
  @epoch_bytes 32

  @type config :: %{mode: :local | :remote, credentials: Credentials.t() | nil}

  @spec boot_config() ::
          {:ok, config()} | {:error, :invalid_owner_auth_configuration}
  def boot_config do
    runtime = Application.get_env(:iex_code, :owner_auth_runtime, [])

    with true <- is_list(runtime) and Keyword.keyword?(runtime),
         {:ok, allow_remote} <- parse_allow_remote(Keyword.get(runtime, :allow_remote)),
         {:ok, config} <- build_config(runtime, allow_remote) do
      System.delete_env("IEX_CODE_AUTH_USERNAME")
      System.delete_env("IEX_CODE_AUTH_PASSWORD_HASH")
      {:ok, config}
    else
      _ -> {:error, :invalid_owner_auth_configuration}
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @spec mode(keyword()) :: :local | :remote | :unavailable
  def mode(opts \\ []) do
    case authority_public(Keyword.get(opts, :table, @default_table)) do
      %{mode: mode} when mode in [:local, :remote] -> mode
      _ -> :unavailable
    end
  end

  @spec ready?(keyword()) :: boolean()
  def ready?(opts \\ []), do: mode(opts) in [:local, :remote]

  @spec session_valid?(term(), keyword()) :: boolean()
  def session_valid?(session, opts \\ []) do
    table = Keyword.get(opts, :table, @default_table)

    case authority_public(table) do
      public when is_map(public) -> valid_session?(session, public, now(public.clock))
      _ -> false
    end
  end

  @spec remaining_ms(term(), keyword()) :: non_neg_integer()
  def remaining_ms(session, opts \\ []) do
    table = Keyword.get(opts, :table, @default_table)

    case authority_public(table) do
      public when is_map(public) ->
        now = now(public.clock)

        if valid_session?(session, public, now) do
          max(session["expires_at_ms"] - now, 0)
        else
          0
        end

      _ ->
        0
    end
  end

  @spec login(term(), term(), keyword()) ::
          {:ok, map()}
          | {:error, :invalid_credentials}
          | {:error, :throttled, pos_integer()}
          | {:error, :unavailable}
  def login(username, password, opts \\ []) do
    if Credentials.valid_input?(username, password) do
      server = Keyword.get(opts, :server, __MODULE__)
      table = Keyword.get(opts, :table, @default_table)

      case mode(table: table) do
        :remote ->
          perform_login(server, username, password)

        :local ->
          {:error, :unavailable}

        :unavailable ->
          {:error, :unavailable}
      end
    else
      {:error, :invalid_credentials}
    end
  end

  @spec logout(term(), keyword()) :: {:ok, binary()} | {:error, :unauthorized | :unavailable}
  def logout(session, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    table = Keyword.get(opts, :table, @default_table)

    cond do
      authority_public(table) == nil ->
        {:error, :unavailable}

      not session_valid?(session, table: table) ->
        {:error, :unauthorized}

      true ->
        safe_call(server, {:logout, session}, :unavailable)
    end
  end

  @impl true
  def init(opts) do
    config =
      opts
      |> Keyword.get(:config, %{mode: :local, credentials: nil})
      |> normalize_config!()

    table = Keyword.get(opts, :table, @default_table)
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    name = Keyword.get(opts, :name, __MODULE__)

    unless is_atom(table) and is_function(clock, 0) do
      raise ArgumentError, "invalid owner auth options"
    end

    epoch = :crypto.strong_rand_bytes(@epoch_bytes)

    public = %{
      mode: config.mode,
      epoch: epoch,
      clock: clock,
      session_lifetime_ms: @session_lifetime_ms
    }

    ^table =
      :ets.new(table, [
        :named_table,
        :set,
        :protected,
        read_concurrency: true
      ])

    true = :ets.insert(table, {:authority, public})

    {:ok,
     %{
       name: name,
       table: table,
       config: config,
       mode: config.mode,
       epoch: epoch,
       clock: clock,
       tokens: @bucket_capacity,
       last_refill_ms: now(clock),
       ticket: nil
     }}
  end

  @impl true
  def handle_call(:admit, {caller, _tag}, state) do
    state = refill(state)

    cond do
      state.mode != :remote or not valid_credentials?(state.config.credentials) ->
        {:reply, {:error, :unavailable}, state}

      state.ticket != nil ->
        {:reply, {:error, :throttled, 1}, state}

      state.tokens == 0 ->
        {:reply, {:error, :throttled, retry_seconds(state)}, state}

      true ->
        ticket = make_ref()
        monitor_ref = Process.monitor(caller)

        ticket_state = %{
          id: ticket,
          caller: caller,
          monitor_ref: monitor_ref,
          epoch: state.epoch
        }

        {:reply, {:ok, self(), ticket, state.epoch, state.config.credentials.salt},
         %{state | tokens: state.tokens - 1, ticket: ticket_state}}
    end
  end

  @impl true
  def handle_call({:complete, ticket, epoch, username_digest, derived_digest}, {caller, _}, state) do
    if owns_ticket?(state.ticket, caller, ticket) do
      {reply, state} = complete_ticket(state, epoch, username_digest, derived_digest)
      {:reply, reply, state}
    else
      {:reply, {:error, :unauthorized}, state}
    end
  end

  @impl true
  def handle_call({:logout, session}, _from, state) do
    public = public_state(state)

    if valid_session?(session, public, now(state.clock)) do
      old_topic = session["live_socket_id"]
      # Do not release an active KDF on rotation; completion or DOWN releases it.
      epoch = :crypto.strong_rand_bytes(@epoch_bytes)
      public = %{public | epoch: epoch}
      true = :ets.insert(state.table, {:authority, public})

      {:reply, {:ok, old_topic}, %{state | epoch: epoch}}
    else
      {:reply, {:error, :unauthorized}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, caller, _reason}, state) do
    if match?(%{monitor_ref: ^monitor_ref, caller: ^caller}, state.ticket) do
      {:noreply, %{state | ticket: nil}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def format_status(status) do
    status
    |> Map.replace(:state, :redacted)
    |> Map.replace(:message, :redacted)
    |> Map.replace(:reason, :redacted)
    |> Map.replace(:log, [])
  end

  defp perform_login(server, username, password) do
    case safe_call(server, :admit, :unavailable) do
      {:ok, authority, ticket, epoch, salt} ->
        username_digest = :crypto.hash(:sha256, username)
        derived_digest = Credentials.derive(password, salt)

        case safe_call(
               authority,
               {:complete, ticket, epoch, username_digest, derived_digest},
               :unavailable
             ) do
          {:ok, session} -> {:ok, session}
          {:error, :throttled, retry_seconds} -> {:error, :throttled, retry_seconds}
          {:error, :unavailable} -> {:error, :unavailable}
          {:error, _} -> {:error, :invalid_credentials}
        end

      {:error, :throttled, retry_seconds} ->
        {:error, :throttled, retry_seconds}

      {:error, :invalid_credentials} ->
        {:error, :invalid_credentials}

      {:error, :unavailable} ->
        {:error, :unavailable}

      _ ->
        {:error, :unavailable}
    end
  end

  defp complete_ticket(state, epoch, username_digest, derived_digest) do
    ticket_epoch = state.ticket.epoch
    state = clear_ticket(state)

    reply =
      cond do
        epoch != state.epoch ->
          {:error, :unauthorized}

        epoch != ticket_epoch ->
          {:error, :unauthorized}

        state.mode != :remote ->
          {:error, :unavailable}

        Credentials.matches?(state.config.credentials, username_digest, derived_digest) ->
          {:ok, issue_session(state)}

        true ->
          {:error, :invalid_credentials}
      end

    {reply, state}
  end

  defp issue_session(state) do
    issued_at_ms = now(state.clock)
    epoch = Base.url_encode64(state.epoch, padding: false)

    %{
      "owner_auth_version" => 1,
      "owner_auth_epoch" => epoch,
      "issued_at_ms" => issued_at_ms,
      "expires_at_ms" => issued_at_ms + @session_lifetime_ms,
      "live_socket_id" => "owner_sessions:" <> epoch
    }
  end

  defp valid_session?(session, public, current_ms) when is_map(session) do
    with true <- public.mode == :remote,
         1 <- Map.get(session, "owner_auth_version"),
         epoch_text when is_binary(epoch_text) and byte_size(epoch_text) == 43 <-
           Map.get(session, "owner_auth_epoch"),
         {:ok, epoch} <- Base.url_decode64(epoch_text, padding: false),
         true <- byte_size(epoch) == @epoch_bytes,
         true <- Base.url_encode64(epoch, padding: false) == epoch_text,
         true <- epoch == public.epoch,
         live_socket_id when is_binary(live_socket_id) <- Map.get(session, "live_socket_id"),
         true <- live_socket_id == "owner_sessions:" <> epoch_text,
         issued_at_ms when is_integer(issued_at_ms) <- Map.get(session, "issued_at_ms"),
         expires_at_ms when is_integer(expires_at_ms) <- Map.get(session, "expires_at_ms"),
         true <- expires_at_ms - issued_at_ms == public.session_lifetime_ms,
         true <- issued_at_ms <= current_ms,
         true <- current_ms < expires_at_ms do
      true
    else
      _ -> false
    end
  end

  defp valid_session?(_session, _public, _current_ms), do: false

  defp authority_public(table) when is_atom(table) do
    case :ets.whereis(table) do
      :undefined ->
        nil

      _table ->
        case :ets.lookup(table, :authority) do
          [{:authority, public}] when is_map(public) -> public
          _ -> nil
        end
    end
  rescue
    ArgumentError -> nil
  end

  defp authority_public(_table), do: nil

  defp public_state(state) do
    %{
      mode: state.mode,
      epoch: state.epoch,
      clock: state.clock,
      session_lifetime_ms: @session_lifetime_ms
    }
  end

  defp normalize_config!(%{mode: mode, credentials: credentials})
       when mode in [:local, :remote] do
    if mode == :local and credentials == nil do
      %{mode: mode, credentials: nil}
    else
      if mode == :remote and valid_credentials?(credentials) do
        %{mode: mode, credentials: credentials}
      else
        raise ArgumentError, "invalid owner auth configuration"
      end
    end
  end

  defp normalize_config!(_config), do: raise(ArgumentError, "invalid owner auth configuration")

  defp valid_credentials?(%{username_digest: username_digest, salt: salt, digest: digest})
       when is_binary(username_digest) and byte_size(username_digest) == @digest_bytes and
              is_binary(salt) and byte_size(salt) == 16 and
              is_binary(digest) and byte_size(digest) == @digest_bytes,
       do: true

  defp valid_credentials?(_), do: false

  defp parse_allow_remote(value) when value in [nil, "", "0", "false", "FALSE"],
    do: {:ok, false}

  defp parse_allow_remote(value) when value in ["1", "true", "TRUE"], do: {:ok, true}
  defp parse_allow_remote(_value), do: {:error, :invalid_owner_auth_configuration}

  defp build_config(_runtime, false) do
    {:ok, %{mode: :local, credentials: nil}}
  end

  defp build_config(runtime, true) do
    endpoint = Application.get_env(:iex_code, IexCodeWeb.Endpoint, [])

    with true <- is_list(endpoint) and Keyword.keyword?(endpoint),
         secret_key_base when is_binary(secret_key_base) <-
           Keyword.get(endpoint, :secret_key_base),
         true <- byte_size(secret_key_base) >= 64,
         true <- Keyword.get(endpoint, :check_origin, true) != false,
         false <- Keyword.get(endpoint, :code_reloader, false) == true,
         false <- Keyword.get(endpoint, :debug_errors, false) == true,
         username when is_binary(username) <- Keyword.get(runtime, :username),
         password_hash when is_binary(password_hash) <- Keyword.get(runtime, :password_hash),
         {:ok, credentials} <- Credentials.parse(username, password_hash) do
      {:ok, %{mode: :remote, credentials: credentials}}
    else
      _ -> {:error, :invalid_owner_auth_configuration}
    end
  end

  defp safe_call(server, request, unavailable) do
    GenServer.call(server, request)
  catch
    :exit, _reason -> {:error, unavailable}
  end

  defp refill(%{tokens: tokens, last_refill_ms: last_refill_ms, clock: clock} = state) do
    current_ms = now(clock)
    elapsed_ms = max(current_ms - last_refill_ms, 0)
    additions = div(elapsed_ms, @refill_interval_ms)

    if tokens + additions >= @bucket_capacity do
      %{state | tokens: @bucket_capacity, last_refill_ms: current_ms}
    else
      %{
        state
        | tokens: min(@bucket_capacity, tokens + additions),
          last_refill_ms: last_refill_ms + additions * @refill_interval_ms
      }
    end
  end

  defp retry_seconds(state) do
    current_ms = now(state.clock)
    elapsed_ms = max(current_ms - state.last_refill_ms, 0)
    remaining_ms = @refill_interval_ms - rem(elapsed_ms, @refill_interval_ms)
    max(div(remaining_ms + 999, 1_000), 1)
  end

  defp owns_ticket?(%{id: id, caller: caller}, caller, id), do: true
  defp owns_ticket?(_ticket, _caller, _id), do: false

  defp clear_ticket(%{ticket: nil} = state), do: state

  defp clear_ticket(%{ticket: %{monitor_ref: monitor_ref}} = state) do
    Process.demonitor(monitor_ref, [:flush])
    %{state | ticket: nil}
  end

  defp now(clock), do: clock.()
end

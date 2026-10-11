defmodule IexCode.OwnerAuthTest do
  use ExUnit.Case, async: false

  alias IexCode.OwnerAuth
  alias IexCode.OwnerAuth.Credentials

  @server __MODULE__.Authority
  @table :iex_code_owner_auth_test
  @opts [server: @server, table: @table]

  setup_all do
    username = "synthetic.owner@example.test"
    password = "synthetic " <> Base.encode64(:crypto.strong_rand_bytes(24))
    salt = :crypto.strong_rand_bytes(16)
    digest = :crypto.pbkdf2_hmac(:sha256, password, salt, 600_000, 32)
    hash = "pbkdf2_sha256$600000$#{Base.encode64(salt)}$#{Base.encode64(digest)}"
    {:ok, credentials} = Credentials.parse(username, hash)

    %{username: username, password: password, hash: hash, credentials: credentials}
  end

  setup do
    previous_runtime = Application.fetch_env(:iex_code, :owner_auth_runtime)
    previous_endpoint = Application.fetch_env(:iex_code, IexCodeWeb.Endpoint)
    env_names = ["IEX_CODE_AUTH_USERNAME", "IEX_CODE_AUTH_PASSWORD_HASH", "IEX_CODE_ALLOW_REMOTE"]
    previous_env = Map.new(env_names, &{&1, System.get_env(&1)})
    clock_ref = :atomics.new(1, signed: true)
    :atomics.put(clock_ref, 1, -100_000)
    clock = fn -> :atomics.get(clock_ref, 1) end

    on_exit(fn ->
      restore_app_env(:owner_auth_runtime, previous_runtime)
      restore_app_env(IexCodeWeb.Endpoint, previous_endpoint)

      for {key, value} <- previous_env do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    %{clock_ref: clock_ref, clock: clock}
  end

  test "absent captured configuration stays local and scrubs inherited credentials", fixture do
    Application.delete_env(:iex_code, :owner_auth_runtime)
    System.put_env("IEX_CODE_ALLOW_REMOTE", "true")
    System.put_env("IEX_CODE_AUTH_USERNAME", fixture.username)
    System.put_env("IEX_CODE_AUTH_PASSWORD_HASH", fixture.hash)

    assert OwnerAuth.boot_config() == {:ok, %{mode: :local, credentials: nil}}
    assert System.get_env("IEX_CODE_AUTH_USERNAME") == nil
    assert System.get_env("IEX_CODE_AUTH_PASSWORD_HASH") == nil
  end

  test "only explicit disabled raw flags select local mode" do
    for flag <- [nil, "", "0", "false", "FALSE"] do
      Application.put_env(:iex_code, :owner_auth_runtime, allow_remote: flag)
      assert OwnerAuth.boot_config() == {:ok, %{mode: :local, credentials: nil}}
    end
  end

  test "enabled raw flags validate captured credentials and scrub inherited environment",
       fixture do
    configure_endpoint([])

    for flag <- ["1", "true", "TRUE"] do
      configure_runtime(fixture, allow_remote: flag)
      System.put_env("IEX_CODE_AUTH_USERNAME", "different-inherited-owner")
      System.put_env("IEX_CODE_AUTH_PASSWORD_HASH", "different-inherited-hash")

      assert {:ok, %{mode: :remote, credentials: credentials}} = OwnerAuth.boot_config()
      assert credentials == fixture.credentials
      assert System.get_env("IEX_CODE_AUTH_USERNAME") == nil
      assert System.get_env("IEX_CODE_AUTH_PASSWORD_HASH") == nil
    end
  end

  test "supervisor child args stay secret-free while init loads private runtime config",
       fixture do
    configure_endpoint([])
    configure_runtime(fixture, [])
    assert {:ok, _} = OwnerAuth.boot_config()

    child = OwnerAuth.child_spec(name: @server, table: @table, clock: fixture.clock)
    start_args = child.start |> elem(2)
    encoded_args = :erlang.term_to_binary(start_args)

    assert :binary.match(encoded_args, fixture.credentials.digest) == :nomatch
    assert :binary.match(encoded_args, fixture.credentials.username_digest) == :nomatch
    assert :binary.match(encoded_args, fixture.credentials.salt) == :nomatch

    pid = start_supervised!(Supervisor.child_spec({OwnerAuth, hd(start_args)}, id: @server))
    assert OwnerAuth.mode(server: @server, table: @table) == :remote
    assert :sys.get_state(pid).config.credentials == fixture.credentials

    supplied = OwnerAuth.child_spec(config: %{mode: :remote, credentials: fixture.credentials})
    assert supplied.start == {OwnerAuth, :start_link, [[]]}

    {:ok, application_child} = :supervisor.get_childspec(IexCode.Supervisor, OwnerAuth)
    assert application_child.start == {OwnerAuth, :start_link, [[]]}
  end

  test "invalid private remote config fails before authority or application children start",
       fixture do
    configure_endpoint([])
    configure_runtime(fixture, password_hash: nil)
    existing_children = Supervisor.which_children(IexCode.Supervisor)

    assert OwnerAuth.init(name: @server, table: @table) ==
             {:stop, :invalid_owner_auth_configuration}

    assert IexCode.Application.start(:normal, []) ==
             {:error, :invalid_owner_auth_configuration}

    assert :ets.whereis(@table) == :undefined
    assert Supervisor.which_children(IexCode.Supervisor) == existing_children
  end

  test "malformed raw flags and runtime configuration fail generically", fixture do
    configure_endpoint([])

    for flag <- ["yes", "False", " true", "true\n", "2", 0, 1, true, false, %{}] do
      configure_runtime(fixture, allow_remote: flag)
      assert OwnerAuth.boot_config() == {:error, :invalid_owner_auth_configuration}
    end

    for runtime <- [nil, %{}, [1], [{"allow_remote", "true"}]] do
      Application.put_env(:iex_code, :owner_auth_runtime, runtime)
      assert OwnerAuth.boot_config() == {:error, :invalid_owner_auth_configuration}
    end
  end

  test "remote boot requires valid credentials and safe endpoint settings", fixture do
    configure_endpoint([])

    for overrides <- [
          [username: nil],
          [username: "owner\n"],
          [password_hash: nil],
          [password_hash: ""],
          [password_hash: fixture.hash <> "$"]
        ] do
      configure_runtime(fixture, overrides)
      assert OwnerAuth.boot_config() == {:error, :invalid_owner_auth_configuration}
    end

    configure_runtime(fixture, [])

    for endpoint <- [
          [secret_key_base: nil],
          [secret_key_base: []],
          [secret_key_base: String.duplicate("k", 63)],
          [check_origin: false],
          [code_reloader: true],
          [debug_errors: true]
        ] do
      configure_endpoint(endpoint)
      assert OwnerAuth.boot_config() == {:error, :invalid_owner_auth_configuration}
    end

    configure_endpoint([])
    assert {:ok, %{mode: :remote}} = OwnerAuth.boot_config()
    configure_endpoint(check_origin: ["https://owner.example.test"])
    assert {:ok, %{mode: :remote}} = OwnerAuth.boot_config()
  end

  test "authority publishes only a protected singleton validation row", fixture do
    pid = start_authority(fixture)

    assert OwnerAuth.mode(@opts) == :remote
    assert OwnerAuth.ready?(@opts)
    assert :ets.info(@table, :owner) == pid
    assert :ets.info(@table, :protection) == :protected
    assert :ets.info(@table, :size) == 1
    assert [{:authority, public}] = :ets.tab2list(@table)
    assert Map.keys(public) |> Enum.sort() == [:clock, :epoch, :mode, :session_lifetime_ms]
    assert byte_size(public.epoch) == 32
    assert public.clock == fixture.clock
    assert public.session_lifetime_ms == 28_800_000
    assert public.mode == :remote

    assert_raise ArgumentError, fn -> :ets.insert(@table, {:authority, %{mode: :local}}) end
    assert :sys.get_state(pid).config.credentials == fixture.credentials
    status = pid |> :sys.get_status() |> :erlang.term_to_binary()
    assert :binary.match(status, fixture.credentials.digest) == :nomatch
    assert :binary.match(status, fixture.credentials.username_digest) == :nomatch
  end

  test "login issues an eight-hour absolute session with exact current epoch", fixture do
    start_authority(fixture)
    assert {:ok, session} = OwnerAuth.login(fixture.username, fixture.password, @opts)
    [{:authority, public}] = :ets.lookup(@table, :authority)

    assert session == %{
             "owner_auth_version" => 1,
             "owner_auth_epoch" => Base.url_encode64(public.epoch, padding: false),
             "issued_at_ms" => -100_000,
             "expires_at_ms" => 28_700_000,
             "live_socket_id" =>
               "owner_sessions:" <> Base.url_encode64(public.epoch, padding: false)
           }

    assert OwnerAuth.session_valid?(session, @opts)
    assert OwnerAuth.remaining_ms(session, @opts) == 28_800_000

    assert OwnerAuth.login(fixture.username, fixture.password <> "!", @opts) ==
             {:error, :invalid_credentials}

    assert OwnerAuth.login("different.owner", fixture.password, @opts) ==
             {:error, :invalid_credentials}
  end

  test "validation rejects malformed sessions and enforces both time boundaries", fixture do
    start_authority(fixture)
    {:ok, session} = OwnerAuth.login(fixture.username, fixture.password, @opts)

    for invalid <- [
          nil,
          [],
          %{},
          %{owner_auth_version: 1},
          Map.put(session, "owner_auth_version", 1.0),
          Map.put(session, "owner_auth_epoch", :crypto.strong_rand_bytes(32)),
          Map.put(session, "owner_auth_epoch", session["owner_auth_epoch"] <> "="),
          Map.put(session, "live_socket_id", "owner_sessions:other"),
          Map.put(session, "issued_at_ms", "-100000"),
          Map.put(session, "issued_at_ms", -100_000.0),
          Map.put(session, "expires_at_ms", 28_700_001),
          Map.put(session, "expires_at_ms", nil),
          Map.delete(session, "live_socket_id")
        ] do
      refute OwnerAuth.session_valid?(invalid, @opts)
      assert OwnerAuth.remaining_ms(invalid, @opts) == 0
    end

    session_with_extra = Map.put(session, "extra", "preserved")
    assert OwnerAuth.session_valid?(session_with_extra, @opts)

    :atomics.put(fixture.clock_ref, 1, -100_001)
    refute OwnerAuth.session_valid?(session, @opts)
    :atomics.put(fixture.clock_ref, 1, 28_699_999)
    assert OwnerAuth.session_valid?(session, @opts)
    assert OwnerAuth.remaining_ms(session, @opts) == 1
    :atomics.put(fixture.clock_ref, 1, 28_700_000)
    refute OwnerAuth.session_valid?(session, @opts)
    assert OwnerAuth.remaining_ms(session, @opts) == 0
  end

  test "hot-path validation never waits on the authority process", fixture do
    pid = start_authority(fixture)
    {:ok, session} = OwnerAuth.login(fixture.username, fixture.password, @opts)
    :ok = :sys.suspend(pid)

    try do
      assert OwnerAuth.ready?(@opts)
      assert OwnerAuth.mode(@opts) == :remote
      assert OwnerAuth.session_valid?(session, @opts)
      assert OwnerAuth.remaining_ms(session, @opts) == 28_800_000
    after
      :sys.resume(pid)
    end
  end

  test "logout rotates before replying and a stale logout cannot revoke newer sessions",
       fixture do
    start_authority(fixture)
    {:ok, first} = OwnerAuth.login(fixture.username, fixture.password, @opts)
    {:ok, second} = OwnerAuth.login(fixture.username, fixture.password, @opts)
    assert {:ok, topic} = OwnerAuth.logout(first, @opts)
    assert topic == first["live_socket_id"]
    refute OwnerAuth.session_valid?(first, @opts)
    refute OwnerAuth.session_valid?(second, @opts)

    {:ok, current} = OwnerAuth.login(fixture.username, fixture.password, @opts)
    assert current["owner_auth_epoch"] != first["owner_auth_epoch"]
    assert OwnerAuth.logout(first, @opts) == {:error, :unauthorized}
    assert OwnerAuth.logout(%{}, @opts) == {:error, :unauthorized}
    assert OwnerAuth.session_valid?(current, @opts)
  end

  test "authority loss fails closed and a restart cannot revive prior sessions", fixture do
    pid = start_authority(fixture)
    {:ok, session} = OwnerAuth.login(fixture.username, fixture.password, @opts)
    monitor = Process.monitor(pid)
    stop_supervised!(@server)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :shutdown}

    assert OwnerAuth.mode(@opts) == :unavailable
    refute OwnerAuth.ready?(@opts)
    refute OwnerAuth.session_valid?(session, @opts)
    assert OwnerAuth.remaining_ms(session, @opts) == 0
    assert OwnerAuth.login(fixture.username, fixture.password, @opts) == {:error, :unavailable}
    assert OwnerAuth.logout(session, @opts) == {:error, :unavailable}

    start_authority(fixture)
    refute OwnerAuth.session_valid?(session, @opts)
    assert {:ok, current} = OwnerAuth.login(fixture.username, fixture.password, @opts)
    assert current["owner_auth_epoch"] != session["owner_auth_epoch"]
  end

  test "local mode is ready but never issues or validates owner sessions", fixture do
    start_authority(fixture, %{mode: :local, credentials: nil})
    assert OwnerAuth.mode(@opts) == :local
    assert OwnerAuth.ready?(@opts)
    assert OwnerAuth.login(fixture.username, fixture.password, @opts) == {:error, :unavailable}
    assert OwnerAuth.logout(%{}, @opts) == {:error, :unauthorized}
    refute OwnerAuth.session_valid?(%{}, @opts)
    assert OwnerAuth.remaining_ms(%{}, @opts) == 0
  end

  test "bad inputs are rejected before admission without consuming tokens", fixture do
    start_authority(fixture)

    for {username, password} <- [
          {"", fixture.password},
          {String.duplicate("a", 65), fixture.password},
          {fixture.username, String.duplicate("p", 1025)},
          {nil, fixture.password},
          {fixture.username, %{"nested" => "password"}},
          {fixture.username, <<255>>}
        ] do
      assert OwnerAuth.login(username, password, @opts) == {:error, :invalid_credentials}
    end

    for index <- 1..5 do
      assert OwnerAuth.login("wrong-owner-#{index}", "wrong", @opts) ==
               {:error, :invalid_credentials}
    end

    assert OwnerAuth.login(fixture.username, fixture.password, @opts) == {:error, :throttled, 12}
    assert :ets.info(@table, :size) == 1
  end

  test "successes and logout do not reset the global bucket and refill is bounded", fixture do
    start_authority(fixture)

    for _ <- 1..5 do
      assert {:ok, session} = OwnerAuth.login(fixture.username, fixture.password, @opts)
      assert {:ok, _topic} = OwnerAuth.logout(session, @opts)
    end

    assert OwnerAuth.login(fixture.username, fixture.password, @opts) == {:error, :throttled, 12}
    :atomics.put(fixture.clock_ref, 1, -88_001)
    assert OwnerAuth.login(fixture.username, fixture.password, @opts) == {:error, :throttled, 1}
    :atomics.put(fixture.clock_ref, 1, -88_000)
    assert {:ok, _} = OwnerAuth.login(fixture.username, fixture.password, @opts)
    assert OwnerAuth.login(fixture.username, fixture.password, @opts) == {:error, :throttled, 12}
    :atomics.put(fixture.clock_ref, 1, 1_000_000)

    for _ <- 1..5 do
      assert OwnerAuth.login("wrong-owner", "wrong", @opts) == {:error, :invalid_credentials}
    end

    assert {:error, :throttled, 12} = OwnerAuth.login("wrong-owner", "wrong", @opts)
  end

  test "only one caller is admitted, denied work is not queued, and caller DOWN frees its ticket",
       fixture do
    pid = start_authority(fixture)
    {worker, admission} = reserve_ticket()
    assert {:ok, ^pid, _ticket, _epoch, salt} = admission
    assert salt == fixture.credentials.salt

    for _ <- 1..10 do
      assert {:error, :throttled, retry} = OwnerAuth.login("other-owner", "wrong", @opts)
      assert retry in 1..12
    end

    monitor = Process.monitor(worker)
    send(worker, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    _ = :sys.get_state(pid)

    for _ <- 1..4 do
      assert OwnerAuth.login("wrong-owner", "wrong", @opts) == {:error, :invalid_credentials}
    end

    assert {:error, :throttled, 12} = OwnerAuth.login("wrong-owner", "wrong", @opts)
  end

  test "logout stays responsive during admission and rejects completion from the prior epoch",
       fixture do
    pid = start_authority(fixture)
    {:ok, session} = OwnerAuth.login(fixture.username, fixture.password, @opts)
    {worker, {:ok, ^pid, ticket, epoch, _salt}} = reserve_ticket()
    assert {:ok, _topic} = OwnerAuth.logout(session, @opts)
    assert {:error, :throttled, _retry} = OwnerAuth.login("other-owner", "wrong", @opts)

    send(
      worker,
      {:complete, ticket, epoch, fixture.credentials.username_digest, fixture.credentials.digest}
    )

    assert_receive {:completed, ^worker, {:error, :unauthorized}}, 1_000
    assert {:ok, current} = OwnerAuth.login(fixture.username, fixture.password, @opts)
    assert OwnerAuth.session_valid?(current, @opts)
  end

  test "a different caller or ticket cannot complete another admission", fixture do
    pid = start_authority(fixture)
    {worker, {:ok, ^pid, ticket, epoch, _salt}} = reserve_ticket()
    credentials = fixture.credentials

    assert GenServer.call(
             pid,
             {:complete, ticket, epoch, credentials.username_digest, credentials.digest}
           ) ==
             {:error, :unauthorized}

    assert GenServer.call(
             pid,
             {:complete, make_ref(), epoch, credentials.username_digest, credentials.digest}
           ) ==
             {:error, :unauthorized}

    assert {:error, :throttled, _} = OwnerAuth.login("other-owner", "wrong", @opts)
    send(worker, {:complete, ticket, epoch, credentials.username_digest, credentials.digest})
    assert_receive {:completed, ^worker, {:ok, session}}, 1_000
    assert OwnerAuth.session_valid?(session, @opts)
  end

  test "a prior ticket cannot claim the new epoch after logout", fixture do
    authority = start_authority(fixture)
    {:ok, session} = OwnerAuth.login(fixture.username, fixture.password, @opts)
    {worker, {:ok, ^authority, ticket, _old_epoch, _salt}} = reserve_ticket()
    assert {:ok, _} = OwnerAuth.logout(session, @opts)
    [{:authority, public}] = :ets.lookup(@table, :authority)

    send(
      worker,
      {:complete, ticket, public.epoch, fixture.credentials.username_digest,
       fixture.credentials.digest}
    )

    assert_receive {:completed, ^worker, {:error, :unauthorized}}, 1_000
  end

  defp start_authority(fixture, config \\ nil) do
    configure_endpoint([])

    if config && config.mode == :local do
      Application.put_env(:iex_code, :owner_auth_runtime, allow_remote: "false")
    else
      configure_runtime(fixture, [])
    end

    opts = [
      name: @server,
      table: @table,
      clock: fixture.clock
    ]

    start_supervised!(Supervisor.child_spec({OwnerAuth, opts}, id: @server))
  end

  defp reserve_ticket do
    parent = self()

    worker =
      start_supervised!(
        {Task,
         fn ->
           admission = GenServer.call(@server, :admit)
           send(parent, {:admitted, self(), admission})

           receive do
             :stop ->
               :ok

             {:complete, ticket, epoch, username_digest, digest} ->
               result =
                 GenServer.call(@server, {:complete, ticket, epoch, username_digest, digest})

               send(parent, {:completed, self(), result})
           end
         end}
      )

    assert_receive {:admitted, ^worker, admission}, 1_000
    {worker, admission}
  end

  defp configure_runtime(fixture, overrides) do
    Application.put_env(
      :iex_code,
      :owner_auth_runtime,
      Keyword.merge(
        [allow_remote: "true", username: fixture.username, password_hash: fixture.hash],
        overrides
      )
    )
  end

  defp configure_endpoint(overrides) do
    Application.put_env(
      :iex_code,
      IexCodeWeb.Endpoint,
      Keyword.merge([secret_key_base: Base.encode64(:crypto.strong_rand_bytes(48))], overrides)
    )
  end

  defp restore_app_env(key, :error), do: Application.delete_env(:iex_code, key)
  defp restore_app_env(key, {:ok, value}), do: Application.put_env(:iex_code, key, value)
end

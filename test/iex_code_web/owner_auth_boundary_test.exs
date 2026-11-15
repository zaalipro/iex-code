defmodule IexCodeWeb.OwnerAuthBoundaryTest do
  use IexCodeWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  alias IexCode.OwnerAuth
  alias IexCode.OwnerAuth.Credentials

  setup_all do
    username = "synthetic.owner"
    password = Base.encode64(:crypto.strong_rand_bytes(32))
    salt = :crypto.strong_rand_bytes(16)
    digest = :crypto.pbkdf2_hmac(:sha256, password, salt, 600_000, 32)
    hash = "pbkdf2_sha256$600000$#{Base.encode64(salt)}$#{Base.encode64(digest)}"

    {:ok, credentials} =
      Credentials.parse(
        username,
        hash
      )

    %{username: username, password: password, hash: hash, credentials: credentials}
  end

  setup fixture do
    previous_runtime = Application.fetch_env(:iex_code, :owner_auth_runtime)

    Application.put_env(:iex_code, :owner_auth_runtime,
      allow_remote: "true",
      username: fixture.username,
      password_hash: fixture.hash
    )

    if Process.whereis(OwnerAuth), do: Supervisor.terminate_child(IexCode.Supervisor, OwnerAuth)
    clock = :atomics.new(1, signed: true)
    :atomics.put(clock, 1, System.monotonic_time(:millisecond))

    start_supervised!({OwnerAuth, clock: fn -> :atomics.get(clock, 1) end})

    on_exit(fn ->
      case previous_runtime do
        {:ok, runtime} -> Application.put_env(:iex_code, :owner_auth_runtime, runtime)
        :error -> Application.delete_env(:iex_code, :owner_auth_runtime)
      end

      Supervisor.restart_child(IexCode.Supervisor, OwnerAuth)
    end)

    %{clock: clock}
  end

  test "all current protected GET and HEAD routes halt before private queries", %{conn: conn} do
    routes = IexCodeWeb.Router.__routes__()

    protected =
      Enum.filter(
        routes,
        &(&1.plug == Phoenix.LiveView.Plug or &1.plug == IexCodeWeb.ResearchReportController)
      )

    assert length(protected) == 23
    ref = make_ref()
    parent = self()
    handler = {__MODULE__, ref}

    :telemetry.attach(
      handler,
      [:iex_code, :repo, :query],
      fn _, _, _, _ ->
        if self() == parent or parent in List.wrap(Process.get(:"$callers")) do
          send(parent, {:query, ref})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    for route <- protected, method <- [:get, :head] do
      path = Regex.replace(~r/:[a-z_]+/, route.path, "987654")
      denied = dispatch(conn, @endpoint, method, path, nil)
      assert denied.status == 302
      assert get_resp_header(denied, "location") == ["/login"]
    end

    refute_receive {:query, ^ref}
  end

  test "public login and readiness have no private initialization", %{conn: conn} do
    ref = make_ref()
    parent = self()
    handler = {__MODULE__, ref}

    :telemetry.attach(
      handler,
      [:iex_code, :repo, :query],
      fn _, _, _, _ ->
        if self() == parent or parent in List.wrap(Process.get(:"$callers")) do
          send(parent, {:query, ref})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    conn = get(conn, "/login")

    assert LazyHTML.query(LazyHTML.from_document(conn.resp_body), "#owner-login-form")
           |> Enum.count() == 1

    assert get(recycle(conn), "/health/ready") |> response(200) == "ok"
    refute_receive {:query, ^ref}
  end

  test "repo query telemetry probe ignores unrelated background processes while catching request and Task callers" do
    ref = make_ref()
    parent = self()
    handler = {__MODULE__, {:caller_scope, ref}}

    :telemetry.attach(
      handler,
      [:iex_code, :repo, :query],
      fn _, _, _, _ ->
        if self() == parent or parent in List.wrap(Process.get(:"$callers")) do
          send(parent, {:query, ref})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {bg_pid, bg_mon} =
      spawn_monitor(fn ->
        Process.delete(:"$callers")
        :telemetry.execute([:iex_code, :repo, :query], %{total_time: 1}, %{})
      end)

    assert_receive {:DOWN, ^bg_mon, :process, ^bg_pid, :normal}
    refute_receive {:query, ^ref}

    Task.async(fn ->
      :telemetry.execute([:iex_code, :repo, :query], %{total_time: 1}, %{})
    end)
    |> Task.await()

    assert_receive {:query, ^ref}

    :telemetry.execute([:iex_code, :repo, :query], %{total_time: 1}, %{})
    assert_receive {:query, ^ref}
  end

  test "authenticated owner reads and downloads a synthetic verified report", fixture do
    root = Path.join(System.tmp_dir!(), "owner-report-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prior = Application.fetch_env(:iex_code, :app_dir)
    Application.put_env(:iex_code, :app_dir, root)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:iex_code, :app_dir, value)
        :error -> Application.delete_env(:iex_code, :app_dir)
      end

      File.rm_rf!(root)
    end)

    {:ok, project} =
      IexCode.Projects.create_project(%{name: "Owner synthetic report", root_path: root})

    {:ok, session} =
      IexCode.Sessions.create_session(%{project_id: project.id, title: "Owner report"})

    {:ok, run} =
      IexCode.Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Synthetic auth report",
        kind: "deep_research",
        mode: "research",
        metadata: %{"research" => %{"level" => "high"}}
      })

    result = IexCode.Research.Results.get_by_run(run)
    {:ok, result} = IexCode.Research.Results.mark_running(result)
    markdown = "# Synthetic owner report\n\nEvidence [1]."
    {:ok, result} = IexCode.Research.Results.commit(result, markdown, source_count: 1)
    owner = login(fixture)
    assert get(recycle(owner), "/research/#{result.id}/report").status == 200
    assert get(recycle(owner), "/research/#{result.id}/report/download").status == 200

    assert get(recycle(owner), "/research/#{result.id}/result/download") |> response(200) ==
             markdown
  end

  test "websocket keeps native missing invalid CSRF and hostile Origin denial", fixture do
    signed_in = login(fixture)
    form = get(csrf_conn(recycle(signed_in)), "/login")

    for path <- ["/live/websocket?vsn=2.0.0", "/live/websocket?vsn=2.0.0&_csrf_token=invalid"] do
      assert get(recycle(form), path).status == 403
    end

    path = "/live/websocket?vsn=2.0.0&_csrf_token=" <> URI.encode_www_form(csrf_token(form))

    assert recycle(form)
           |> put_req_header("origin", "https://attacker.example")
           |> get(path)
           |> response(403) == ""
  end

  test "tampered encrypted cookie cannot authorize", fixture do
    first = login(fixture)
    cookie = first.resp_cookies["_iex_code_key"].value
    forged = Plug.Test.put_req_cookie(fixture.conn, "_iex_code_key", "x" <> cookie)
    assert get(forged, "/settings").status == 302
    config = IexCodeWeb.Endpoint.session_options() |> Keyword.delete(:encryption_salt)
    conn = %{fixture.conn | secret_key_base: IexCodeWeb.Endpoint.config(:secret_key_base)}
    assert {nil, %{}} = Plug.Session.COOKIE.get(conn, cookie, Plug.Session.COOKIE.init(config))
  end

  test "local passwordless route and transport require both actual peer and Host", fixture do
    stop_supervised!(OwnerAuth)
    Application.put_env(:iex_code, :owner_auth_runtime, allow_remote: "false")
    start_supervised!({OwnerAuth, []})
    assert get(fixture.conn, "/settings").status == 200

    for path <- ["/settings", "/live/websocket", "/live/longpoll"] do
      assert get(%{fixture.conn | remote_ip: {10, 0, 0, 5}}, path).status == 403
      assert get(%{fixture.conn | host: "attacker.example"}, path).status == 403
    end
  end

  test "login is generic, renews encrypted secure session and logout revokes both sessions",
       fixture do
    conn = get(csrf_conn(fixture.conn), "/login")

    bad =
      post(csrf_conn(recycle(conn)), "/login", %{
        "owner" => %{"username" => fixture.username, "password" => "invalid"},
        "_csrf_token" => csrf_token(conn)
      })

    assert bad.status == 401

    assert LazyHTML.query(LazyHTML.from_document(bad.resp_body), "#owner-password[value]")
           |> Enum.count() == 0

    first = login(fixture)
    second = login(fixture)
    cookie = first.resp_cookies["_iex_code_key"]
    assert cookie.http_only
    assert cookie.secure
    assert cookie.same_site == "Lax"
    assert cookie.path == "/"
    refute Map.has_key?(cookie, :domain)
    refute String.contains?(cookie.value, fixture.username)
    refute String.contains?(cookie.value, fixture.password)
    assert get_session(first, "owner_auth_version") == 1

    logout_form = get(csrf_conn(recycle(first)), "/login")

    out =
      post(csrf_conn(recycle(logout_form)), "/logout", %{"_csrf_token" => csrf_token(logout_form)})

    assert out.status == 302

    for signed_in <- [first, second] do
      assert get(recycle(signed_in), "/settings").status == 302
    end

    third = login(fixture)
    stale_form = get(csrf_conn(recycle(second)), "/login")

    stale =
      post(csrf_conn(recycle(stale_form)), "/logout", %{"_csrf_token" => csrf_token(stale_form)})

    assert stale.status == 302
    assert get(recycle(third), "/settings").status == 200
  end

  test "debug login dispatch logs redact both owner credentials", fixture do
    previous_level = Logger.level()
    Logger.configure(level: :debug)

    try do
      log =
        capture_log([level: :debug], fn ->
          conn = get(csrf_conn(fixture.conn), "/login")

          response =
            post(csrf_conn(recycle(conn)), "/login", %{
              "owner" => %{"username" => fixture.username, "password" => fixture.password},
              "_csrf_token" => csrf_token(conn)
            })

          assert response.status == 302
        end)

      assert log =~ "Processing with IexCodeWeb.OwnerSessionController.create/2"
      assert log =~ ~s(Parameters: %{"_csrf_token" => "[FILTERED]")
      assert log =~ ~s("owner" => %{"password" => "[FILTERED]", "username" => "[FILTERED]"})
      refute log =~ fixture.username
      refute log =~ fixture.password
    after
      Logger.configure(level: previous_level)
    end
  end

  test "login and logout reject missing CSRF and GET logout never revokes", fixture do
    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      post(csrf_conn(fixture.conn), "/login", %{
        "owner" => %{"username" => fixture.username, "password" => fixture.password}
      })
    end

    first = login(fixture)
    conn = recycle(first) |> put_private(:plug_skip_csrf_protection, false)
    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn -> post(conn, "/logout", %{}) end
    assert get(recycle(first), "/logout").status == 404
    assert OwnerAuth.session_valid?(get_session(first))
  end

  test "guest and revoked transport requests halt before dispatch including resumes", fixture do
    for method <- [:get, :post, :options], path <- ["/live/websocket", "/live/longpoll"] do
      conn = dispatch(fixture.conn, @endpoint, method, path <> "?token=not-an-authority", nil)
      assert conn.status == 403
      assert conn.halted
    end

    first = login(fixture)
    {:ok, _} = OwnerAuth.logout(get_session(first))

    for method <- [:get, :post] do
      conn = dispatch(recycle(first), @endpoint, method, "/live/longpoll?token=prior-token", nil)
      assert conn.status == 403
    end
  end

  test "real longpoll handshake and token resumes retain native CSRF and Origin checks",
       fixture do
    signed_in = login(fixture)
    form = get(csrf_conn(recycle(signed_in)), "/login")
    token = csrf_token(form)
    path = "/live/longpoll?vsn=2.0.0&_csrf_token=" <> URI.encode_www_form(token)
    initial = get(recycle(form), path)
    assert initial.status == 200
    initial_body = Jason.decode!(initial.resp_body)
    assert initial_body["status"] == 410
    lp_token = initial_body["token"]
    assert is_binary(lp_token)

    heartbeat = Jason.encode!([nil, "heartbeat-ref", "phoenix", "heartbeat", %{}])

    sent =
      recycle(form)
      |> put_req_header("x-phoenix-longpoll-token", lp_token)
      |> put_req_header("content-type", "application/json")
      |> post("/live/longpoll?vsn=2.0.0", heartbeat)

    assert Jason.decode!(sent.resp_body)["status"] == 200

    polled =
      recycle(form)
      |> put_req_header("x-phoenix-longpoll-token", lp_token)
      |> get("/live/longpoll?vsn=2.0.0")

    assert Jason.decode!(polled.resp_body)["status"] == 200
    assert length(Jason.decode!(polled.resp_body)["messages"]) == 1

    for missing_csrf <- [
          "/live/longpoll?vsn=2.0.0",
          "/live/longpoll?vsn=2.0.0&_csrf_token=invalid"
        ] do
      response = get(recycle(form), missing_csrf)
      assert Jason.decode!(response.resp_body)["status"] == 403
    end

    hostile = recycle(form) |> put_req_header("origin", "https://attacker.example") |> get(path)
    assert Jason.decode!(hostile.resp_body)["status"] == 403

    for method <- [:get, :post], placement <- [:header, :query] do
      path =
        if placement == :query,
          do: "/live/longpoll?token=" <> URI.encode_www_form(lp_token),
          else: "/live/longpoll"

      guest =
        if placement == :header,
          do: put_req_header(fixture.conn, "x-phoenix-longpoll-token", lp_token),
          else: fixture.conn

      response =
        dispatch(
          put_req_header(guest, "content-type", "application/json"),
          @endpoint,
          method,
          path,
          heartbeat
        )

      assert response.status == 403
    end

    {:ok, _} = OwnerAuth.logout(get_session(signed_in))

    for method <- [:get, :post] do
      old =
        recycle(form)
        |> put_req_header("x-phoenix-longpoll-token", lp_token)
        |> put_req_header("content-type", "application/json")

      assert dispatch(old, @endpoint, method, "/live/longpoll", heartbeat).status == 403
    end
  end

  test "oversized login body is rejected before consuming the password bucket", fixture do
    body = "owner%5Bpassword%5D=" <> String.duplicate("p", 16_385)

    assert_raise Plug.Parsers.RequestTooLargeError, fn ->
      fixture.conn
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post("/login", body)
    end

    for _ <- 1..5, do: assert({:ok, _} = OwnerAuth.login(fixture.username, fixture.password))
  end

  test "idle checks reject expired connected owner", fixture do
    first = login(fixture)
    {:ok, view, _} = live(recycle(first), "/settings")
    :atomics.put(fixture.clock, 1, get_session(first, "expires_at_ms"))
    send(view.pid, :owner_auth_tick)
    assert_redirect(view, "/login")
    assert get(recycle(first), "/settings").status == 302
  end

  test "expired event cannot reach the protected settings handler", fixture do
    first = login(fixture)
    {:ok, view, _} = live(recycle(first), "/settings")
    :atomics.put(fixture.clock, 1, get_session(first, "expires_at_ms"))
    assert {:error, {:redirect, %{to: "/login"}}} = render_click(view, "discard_settings")
  end

  test "expired live patch cannot reach protected params", fixture do
    first = login(fixture)
    {:ok, view, _} = live(recycle(first), "/settings")
    :atomics.put(fixture.clock, 1, get_session(first, "expires_at_ms"))
    assert {:error, {:redirect, %{to: "/login"}}} = render_patch(view, "/settings/appearance")
  end

  test "expired ordinary info cannot keep the protected view alive", fixture do
    first = login(fixture)
    {:ok, view, _} = live(recycle(first), "/settings")
    :atomics.put(fixture.clock, 1, get_session(first, "expires_at_ms"))
    send(view.pid, :auth_synthetic_info)
    assert_redirect(view, "/login")
  end

  test "authority loss denies requests login and readiness without local fallback", fixture do
    stop_supervised!(OwnerAuth)
    assert get(fixture.conn, "/health/ready") |> response(503) == "unavailable"
    assert get(fixture.conn, "/settings").status == 503
    assert OwnerAuth.login(fixture.username, fixture.password) == {:error, :unavailable}
  end

  defp csrf_conn(conn), do: put_private(conn, :plug_skip_csrf_protection, false)

  defp csrf_token(conn) do
    conn.resp_body
    |> LazyHTML.from_document()
    |> LazyHTML.query("meta[name=csrf-token]")
    |> LazyHTML.attribute("content")
    |> hd()
  end

  defp login(fixture) do
    conn = get(csrf_conn(fixture.conn), "/login")

    post(csrf_conn(recycle(conn)), "/login", %{
      "owner" => %{"username" => fixture.username, "password" => fixture.password},
      "_csrf_token" => csrf_token(conn)
    })
  end
end

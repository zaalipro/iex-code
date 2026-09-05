defmodule IexCode.Desktop.NativeShortcuts do
  @moduledoc """
  Bridges native WebView keyboard events that WKWebView consumes before wx menu
  accelerators. The private navigation is vetoed locally and never reaches HTTP.
  """

  @compile {:no_warn_undefined, [:wxWebView, :wxWebViewEvent, :wxEvent]}

  alias IexCode.Desktop.Lifecycle

  def install(window_pid, listener_pid, opts \\ []) do
    webview_fn = Keyword.get(opts, :webview_fn, &Desktop.Window.webview/1)
    webview = webview_fn.(window_pid)
    nonce = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    bridge = %{
      webview: webview,
      nonce: nonce,
      quit_url: "iexcode-native://quit/" <> nonce,
      origin: Keyword.get_lazy(opts, :origin, &IexCodeWeb.Endpoint.url/0)
    }

    :sys.replace_state(window_pid, fn state ->
      :ok = connect(bridge, listener_pid, opts)
      state
    end)

    {:ok, bridge}
  rescue
    error -> {:error, {:native_shortcut_binding_failed, error}}
  catch
    kind, reason -> {:error, {:native_shortcut_binding_failed, {kind, reason}}}
  end

  def inject(bridge, opts \\ []) do
    setup_fn = Keyword.get(opts, :setup_fn, &Desktop.Env.wx_use_env/0)
    current_url_fn = Keyword.get(opts, :current_url_fn, &:wxWebView.getCurrentURL/1)
    run_script_fn = Keyword.get(opts, :run_script_fn, &:wxWebView.runScript/2)
    :ok = setup_fn.()

    if same_origin?(current_url_fn.(bridge.webview), bridge.origin) do
      case run_script_fn.(bridge.webview, script(bridge)) do
        {true, _output} -> :ok
        other -> {:error, {:native_shortcut_script_failed, other}}
      end
    else
      :ok
    end
  rescue
    error -> {:error, {:native_shortcut_script_failed, error}}
  catch
    kind, reason -> {:error, {:native_shortcut_script_failed, {kind, reason}}}
  end

  @doc false
  def script(bridge) do
    """
    (() => {
      const origin = new URL(#{Jason.encode!(bridge.origin)}).origin;
      if (window.top !== window || location.origin !== origin) return false;
      const key = "__iexCodeNativeQuit";
      if (window[key]) window.removeEventListener("keydown", window[key], true);
      const handler = event => {
        if (location.origin === origin && event.isTrusted && event.metaKey &&
            !event.ctrlKey && !event.altKey && !event.shiftKey && !event.repeat &&
            event.key.toLowerCase() === "q") {
          event.preventDefault();
          event.stopImmediatePropagation();
          location.href = #{Jason.encode!(bridge.quit_url)};
        }
      };
      window[key] = handler;
      window.addEventListener("keydown", handler, true);
      return true;
    })();
    """
  end

  defp connect(bridge, listener_pid, opts) do
    setup_fn = Keyword.get(opts, :setup_fn, &Desktop.Env.wx_use_env/0)
    disconnect_fn = Keyword.get(opts, :disconnect_fn, &:wxWebView.disconnect/2)
    connect_fn = Keyword.get(opts, :connect_fn, &connect_event/3)
    event_url_fn = Keyword.get(opts, :event_url_fn, &:wxWebViewEvent.getURL/1)
    current_url_fn = Keyword.get(opts, :current_url_fn, &:wxWebView.getCurrentURL/1)
    veto_fn = Keyword.get(opts, :veto_fn, &:wxWebViewEvent.veto/1)
    skip_fn = Keyword.get(opts, :skip_fn, &:wxEvent.skip/1)
    quit_fn = Keyword.get(opts, :quit_fn, &Lifecycle.request_quit/0)
    :ok = setup_fn.()
    _ = disconnect_fn.(bridge.webview, :webview_navigating)
    _ = disconnect_fn.(bridge.webview, :webview_loaded)

    :ok =
      connect_fn.(bridge.webview, :webview_navigating, fn _event, event_object ->
        if to_string(event_url_fn.(event_object)) == bridge.quit_url do
          veto_fn.(event_object)

          if same_origin?(current_url_fn.(bridge.webview), bridge.origin) do
            quit_fn.()
          end
        else
          skip_fn.(event_object)
        end
      end)

    connect_fn.(bridge.webview, :webview_loaded, fn _event, event_object ->
      # runScript is synchronous; only schedule it here so the Cocoa callback
      # can finish before JavaScript runs on the native UI thread.
      send(listener_pid, {:inject_native_shortcuts, bridge.nonce, 0})
      skip_fn.(event_object)
    end)
  end

  defp connect_event(webview, event, callback) do
    :wxWebView.connect(webview, event, callback: callback)
  end

  defp same_origin?(url, expected_url) do
    origin = origin(url)
    origin != nil and origin == origin(expected_url)
  end

  defp origin(url) do
    case URI.parse(to_string(url)) do
      %URI{scheme: scheme, host: host, port: port, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) ->
        {scheme, String.downcase(host), port}

      _ ->
        nil
    end
  end
end

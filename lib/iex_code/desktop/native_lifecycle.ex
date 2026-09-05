defmodule IexCode.Desktop.NativeLifecycle do
  @moduledoc """
  Owns native macOS lifecycle bindings that must survive WebView focus and
  bypass the generic `Desktop.Window` Exit handler.
  """

  use GenServer

  @compile {:no_warn_undefined, [:wxFrame, :wxMenu, :wxMenuBar]}

  require Logger

  alias IexCode.Desktop.{Lifecycle, NativeShortcuts}

  @retry_ms 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  def install_quit_handler(opts \\ []) do
    window_pid = Keyword.get_lazy(opts, :window_pid, fn -> window_pid(opts) end)
    frame_fn = Keyword.get(opts, :frame_fn, fn -> Desktop.Window.frame(window_pid) end)

    with pid when is_pid(pid) <- window_pid,
         frame when not is_nil(frame) <- frame_fn.() do
      # wx subscriptions belong to the subscribing Erlang process. Run the
      # replacement in Desktop.Window so disconnect actually removes its
      # listeners and the replacement callbacks have the window's lifetime.
      # Keep wx_object's opaque system state unchanged; no internal shape is used.
      :sys.replace_state(pid, fn state ->
        :ok = install_frame_handlers(frame, opts)
        state
      end)

      :ok
    else
      _ -> {:error, :window_unavailable}
    end
  rescue
    error -> {:error, {:native_quit_binding_failed, error}}
  catch
    kind, reason -> {:error, {:native_quit_binding_failed, {kind, reason}}}
  end

  defp install_frame_handlers(frame, opts) do
    setup_fn = Keyword.get(opts, :setup_fn, &Desktop.Env.wx_use_env/0)
    menubar_fn = Keyword.get(opts, :menubar_fn, &:wxFrame.getMenuBar/1)
    apple_menu_fn = Keyword.get(opts, :apple_menu_fn, &:wxMenuBar.oSXGetAppleMenu/1)
    exit_id_fn = Keyword.get(opts, :exit_id_fn, &Desktop.Wx.wxID_EXIT/0)
    disconnect_fn = Keyword.get(opts, :disconnect_fn, &:wxFrame.disconnect/2)
    menu_disconnect_fn = Keyword.get(opts, :menu_disconnect_fn, &:wxMenu.disconnect/3)
    close_connect_fn = Keyword.get(opts, :close_connect_fn, &connect_close/2)
    frame_connect_fn = Keyword.get(opts, :frame_connect_fn, &connect_frame_menu/4)
    connect_fn = Keyword.get(opts, :connect_fn, &connect_menu/4)
    quit_fn = Keyword.get(opts, :quit_fn, &Lifecycle.request_quit/0)

    with :ok <- setup_fn.(),
         menubar when not is_nil(menubar) <- menubar_fn.(frame),
         apple_menu when not is_nil(apple_menu) <- apple_menu_fn.(menubar) do
      # Desktop.Window installs a frame-wide wxID_EXIT handler that hard-halts
      # before application cleanup. Remove that listener before installing the
      # application-owned frame and Apple-menu callbacks.
      _ = disconnect_fn.(frame, :command_menu_selected)
      _ = disconnect_fn.(frame, :close_window)
      exit_id = exit_id_fn.()
      _ = menu_disconnect_fn.(apple_menu, :command_menu_selected, id: exit_id)

      with :ok <- close_connect_fn.(frame, quit_fn),
           :ok <- frame_connect_fn.(frame, :command_menu_selected, quit_fn, exit_id),
           :ok <-
             connect_fn.(
               apple_menu,
               :command_menu_selected,
               quit_fn,
               exit_id
             ) do
        :ok
      else
        {:error, _reason} = error -> error
        other -> {:error, {:native_quit_binding_failed, other}}
      end
    else
      nil -> {:error, :window_unavailable}
    end
  end

  @impl true
  def init(opts) do
    send(self(), :install_quit_handler)
    {:ok, %{opts: opts, installed?: false, window_ref: nil, retries: 0, shortcuts: nil}}
  end

  @impl true
  def handle_info(:install_quit_handler, %{installed?: true} = state), do: {:noreply, state}

  def handle_info(:install_quit_handler, state) do
    window_pid = window_pid(state.opts)
    window_ref = if is_pid(window_pid), do: Process.monitor(window_pid)

    shortcuts_install_fn =
      Keyword.get(state.opts, :shortcuts_install_fn, &NativeShortcuts.install/3)

    result =
      with :ok <- install_quit_handler(Keyword.put(state.opts, :window_pid, window_pid)) do
        shortcuts_install_fn.(window_pid, self(), Keyword.get(state.opts, :shortcuts_opts, []))
      end

    case result do
      {:ok, shortcuts} ->
        Logger.info("IexCode.Desktop.NativeLifecycle: Installed native macOS Quit handler")
        send(self(), {:inject_native_shortcuts, shortcuts.nonce, 0})

        {:noreply,
         %{state | installed?: true, window_ref: window_ref, retries: 0, shortcuts: shortcuts}}

      {:error, reason} ->
        if window_ref, do: Process.demonitor(window_ref, [:flush])

        if rem(state.retries, 50) == 0 do
          Logger.warning(
            "IexCode.Desktop.NativeLifecycle: Native Quit binding unavailable; retrying: #{inspect(reason)}"
          )
        end

        Process.send_after(self(), :install_quit_handler, @retry_ms)
        {:noreply, %{state | retries: state.retries + 1}}
    end
  end

  def handle_info({:DOWN, window_ref, :process, _pid, _reason}, %{window_ref: window_ref} = state) do
    Process.send_after(self(), :install_quit_handler, @retry_ms)
    {:noreply, %{state | installed?: false, window_ref: nil, shortcuts: nil}}
  end

  def handle_info(
        {:inject_native_shortcuts, nonce, attempt},
        %{shortcuts: %{nonce: nonce} = shortcuts} = state
      ) do
    inject_fn = Keyword.get(state.opts, :shortcuts_inject_fn, &NativeShortcuts.inject/2)

    case inject_fn.(shortcuts, Keyword.get(state.opts, :shortcuts_opts, [])) do
      :ok ->
        :ok

      {:error, _reason} when attempt < 10 ->
        Process.send_after(self(), {:inject_native_shortcuts, nonce, attempt + 1}, @retry_ms)

      {:error, reason} ->
        Logger.warning(
          "IexCode.Desktop.NativeLifecycle: Native keyboard shortcut unavailable: #{inspect(reason)}"
        )
    end

    {:noreply, state}
  end

  def handle_info({:inject_native_shortcuts, _stale_nonce, _attempt}, state) do
    {:noreply, state}
  end

  defp window_pid(opts) do
    window_fn = Keyword.get(opts, :window_fn, fn -> Process.whereis(IexCodeWindow) end)
    window_fn.()
  end

  defp connect_menu(menu, event, quit_fn, id) do
    :wxMenu.connect(menu, event, id: id, callback: fn _, _ -> quit_fn.() end)
  end

  defp connect_frame_menu(frame, event, quit_fn, id) do
    # Keyboard accelerators can dispatch to the frame instead of the Apple menu.
    # Restrict this listener to Quit so other menu commands keep their handlers.
    :wxFrame.connect(frame, event, id: id, callback: fn _, _ -> quit_fn.() end)
  end

  defp connect_close(frame, quit_fn) do
    :wxFrame.connect(frame, :close_window,
      callback: fn _event, event_object ->
        Desktop.Platform.Window.close_event_veto(event_object)
        quit_fn.()
      end
    )

    :ok
  end
end

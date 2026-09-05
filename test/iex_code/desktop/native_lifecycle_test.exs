defmodule IexCode.Desktop.NativeLifecycleTest do
  use ExUnit.Case, async: true

  alias IexCode.Desktop.NativeLifecycle

  test "binds Apple and frame quit commands directly to the application quit callback" do
    test_pid = self()
    owner = start_supervised!({Agent, fn -> :window_state end})

    assert :ok =
             NativeLifecycle.install_quit_handler(
               window_fn: fn -> owner end,
               setup_fn: fn -> :ok end,
               frame_fn: fn -> :main_frame end,
               menubar_fn: fn :main_frame -> :main_menubar end,
               apple_menu_fn: fn :main_menubar -> :apple_menu end,
               exit_id_fn: fn -> 5006 end,
               disconnect_fn: fn frame, event ->
                 send(test_pid, {:disconnected, self(), frame, event})
                 true
               end,
               menu_disconnect_fn: fn :apple_menu, :command_menu_selected, [id: 5006] ->
                 send(test_pid, {:apple_disconnected, self()})
                 true
               end,
               close_connect_fn: fn frame, callback ->
                 send(test_pid, {:close_connected, self(), frame})
                 callback.()
                 :ok
               end,
               frame_connect_fn: fn frame, event, callback, id ->
                 send(test_pid, {:frame_connected, self(), frame, event, id})
                 callback.()
                 :ok
               end,
               connect_fn: fn menu, event, callback, id ->
                 send(test_pid, {:connected, self(), menu, event, id})
                 callback.()
                 :ok
               end,
               quit_fn: fn -> send(test_pid, :quit_requested) end
             )

    assert_receive {:disconnected, ^owner, :main_frame, :command_menu_selected}
    assert_receive {:disconnected, ^owner, :main_frame, :close_window}
    assert_receive {:apple_disconnected, ^owner}
    assert_receive {:close_connected, ^owner, :main_frame}
    assert_receive {:frame_connected, ^owner, :main_frame, :command_menu_selected, 5006}
    assert_receive {:connected, ^owner, :apple_menu, :command_menu_selected, 5006}
    assert_receive :quit_requested, 100
    assert_receive :quit_requested, 100
    assert_receive :quit_requested, 100
    assert Agent.get(owner, & &1) == :window_state
  end

  test "reports unavailable native handles so its server can retry" do
    assert {:error, :window_unavailable} =
             NativeLifecycle.install_quit_handler(window_fn: fn -> nil end)
  end

  test "rebinds to the replacement window after the installed window exits" do
    test_pid = self()
    owner = start_supervised!(Supervisor.child_spec({Agent, fn -> :first end}, id: :first))

    replacement =
      start_supervised!(Supervisor.child_spec({Agent, fn -> :second end}, id: :second))

    locator = start_supervised!(Supervisor.child_spec({Agent, fn -> owner end}, id: :locator))

    lifecycle =
      start_supervised!(
        {NativeLifecycle,
         window_fn: fn -> Agent.get(locator, & &1) end,
         setup_fn: fn -> :ok end,
         frame_fn: fn ->
           send(test_pid, {:frame_lookup, Agent.get(locator, & &1)})
           :main_frame
         end,
         menubar_fn: fn :main_frame -> :main_menubar end,
         apple_menu_fn: fn :main_menubar -> :apple_menu end,
         exit_id_fn: fn -> 5006 end,
         disconnect_fn: fn _, _ -> true end,
         menu_disconnect_fn: fn _, _, _ -> false end,
         close_connect_fn: fn _, _ -> :ok end,
         frame_connect_fn: fn _, _, _, _ -> :ok end,
         connect_fn: fn _, _, _, _ -> :ok end,
         shortcuts_install_fn: fn pid, listener, _opts ->
           bridge = %{nonce: make_ref()}
           send(test_pid, {:shortcuts_installed, pid, listener, bridge.nonce})
           {:ok, bridge}
         end,
         shortcuts_inject_fn: fn bridge, _opts ->
           send(test_pid, {:shortcuts_injected, bridge.nonce})
           :ok
         end}
      )

    assert_receive {:frame_lookup, ^owner}
    assert :sys.get_state(lifecycle).installed?
    assert_receive {:shortcuts_installed, ^owner, ^lifecycle, first_nonce}
    assert_receive {:shortcuts_injected, ^first_nonce}
    send(lifecycle, {:inject_native_shortcuts, first_nonce, 0})
    assert_receive {:shortcuts_injected, ^first_nonce}
    Agent.update(locator, fn _ -> replacement end)
    stop_supervised!(:first)

    assert_receive {:frame_lookup, ^replacement}, 1_000
    assert :sys.get_state(lifecycle).installed?
    assert_receive {:shortcuts_installed, ^replacement, ^lifecycle, next_nonce}
    assert_receive {:shortcuts_injected, ^next_nonce}
    refute first_nonce == next_nonce
    send(lifecycle, {:inject_native_shortcuts, first_nonce, 0})
    _ = :sys.get_state(lifecycle)
    refute_received {:shortcuts_injected, ^first_nonce}
  end
end

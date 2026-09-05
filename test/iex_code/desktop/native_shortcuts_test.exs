defmodule IexCode.Desktop.NativeShortcutsTest do
  use ExUnit.Case, async: true

  alias IexCode.Desktop.NativeShortcuts

  test "private navigation requests quit only from the app origin and never navigates" do
    test_pid = self()
    current_url = start_supervised!({Agent, fn -> "http://localhost:4140/settings" end})
    owner = start_supervised!(Supervisor.child_spec({Agent, fn -> :window end}, id: :window))

    assert {:ok, bridge} =
             NativeShortcuts.install(owner, self(),
               setup_fn: fn -> :ok end,
               webview_fn: fn _ -> :webview end,
               origin: "http://localhost:4140",
               disconnect_fn: fn _, _ -> false end,
               connect_fn: fn :webview, event, callback ->
                 send(test_pid, {:callback, event, callback})
                 :ok
               end,
               event_url_fn: fn event -> event.url end,
               current_url_fn: fn :webview -> Agent.get(current_url, & &1) end,
               veto_fn: fn _ -> send(test_pid, :vetoed) end,
               skip_fn: fn _ -> send(test_pid, :skipped) end,
               quit_fn: fn -> send(test_pid, :quit_requested) end
             )

    assert_receive {:callback, :webview_navigating, navigating}
    assert_receive {:callback, :webview_loaded, loaded}

    navigating.(:event, %{url: "http://localhost:4140/other"})
    assert_receive :skipped
    refute_received :quit_requested

    navigating.(:event, %{url: bridge.quit_url})
    assert_receive :vetoed
    assert_receive :quit_requested

    Agent.update(current_url, fn _ -> "http://localhost:4141/" end)
    navigating.(:event, %{url: bridge.quit_url})
    assert_receive :vetoed
    refute_received :quit_requested

    loaded.(:event, :loaded_event)
    assert_receive {:inject_native_shortcuts, nonce, 0}
    assert nonce == bridge.nonce
    assert_receive :skipped
  end

  test "script handles trusted Cmd-Q once per document and rejects other origins and keys" do
    bridge = %{
      origin: "http://localhost:4140",
      quit_url: "iexcode-native://quit/0123456789abcdef"
    }

    script = NativeShortcuts.script(bridge)

    harness = """
    const assert = require('node:assert/strict');
    const vm = require('node:vm');
    const script = #{Jason.encode!(script)};
    const listeners = new Set();
    const location = { origin: 'http://localhost:4140', href: '/settings' };
    const window = {
      addEventListener(type, listener, capture) {
        assert.equal(type, 'keydown'); assert.equal(capture, true); listeners.add(listener);
      },
      removeEventListener(type, listener, capture) {
        assert.equal(type, 'keydown'); assert.equal(capture, true); listeners.delete(listener);
      }
    };
    window.top = window;
    const context = vm.createContext({ window, location, URL });
    vm.runInContext(script, context);
    vm.runInContext(script, context);
    assert.equal(listeners.size, 1);
    const handler = [...listeners][0];
    const event = { key: 'q', isTrusted: true, metaKey: true, ctrlKey: false,
      altKey: false, shiftKey: false, repeat: false,
      preventDefault() { this.prevented = true; },
      stopImmediatePropagation() { this.stopped = true; } };
    for (const variant of [ { isTrusted: false }, { ctrlKey: true }, { altKey: true },
      { shiftKey: true }, { repeat: true }, { metaKey: false }, { key: 'n' } ]) {
      handler({ ...event, ...variant });
      assert.equal(location.href, '/settings');
    }
    handler(event);
    assert.equal(location.href, 'iexcode-native://quit/0123456789abcdef');
    assert.equal(event.prevented, true);
    assert.equal(event.stopped, true);
    location.href = '/settings';
    location.origin = 'http://localhost:4141';
    handler({ ...event });
    assert.equal(location.href, '/settings');
    listeners.clear();
    vm.runInContext(script, context);
    assert.equal(listeners.size, 0);
    console.log('native shortcut guards passed');
    """

    assert {"native shortcut guards passed\n", 0} = System.cmd("node", ["-e", harness])
  end
end

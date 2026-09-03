defmodule IexCode.Desktop.WindowManagerTest do
  use ExUnit.Case, async: true

  alias IexCode.Desktop.WindowManager

  describe "window configurations" do
    test "window_configs/0 returns canonical configurations for all detached tools" do
      configs = WindowManager.window_configs()

      assert Map.has_key?(configs, :terminal)
      assert Map.has_key?(configs, :diff)
      assert Map.has_key?(configs, :dag)

      assert configs.terminal.id == IexCodeTerminalWindow
      assert configs.terminal.size == {1040, 720}
      assert configs.terminal.min_size == {640, 480}

      assert configs.diff.id == IexCodeDiffWindow
      assert configs.diff.size == {1280, 840}

      assert configs.dag.id == IexCodeDagWindow
      assert configs.dag.size == {1360, 880}
    end

    test "get_config/1 resolves by atom or string" do
      assert WindowManager.get_config(:terminal) == WindowManager.get_config("terminal")
      assert WindowManager.get_config(:diff) == WindowManager.get_config("diff")
      assert WindowManager.get_config(:dag) == WindowManager.get_config("dag")
      assert is_nil(WindowManager.get_config("unknown"))
    end

    test "window_id/1 returns correct atom IDs" do
      assert WindowManager.window_id(:terminal) == IexCodeTerminalWindow
      assert WindowManager.window_id("diff") == IexCodeDiffWindow
      assert WindowManager.window_id("dag") == IexCodeDagWindow
    end

    test "window_path/2 and window_url/2 generate correct routes" do
      assert WindowManager.window_path(:terminal, "sess_123") ==
               "/sessions/sess_123/detached/terminal"

      assert WindowManager.window_path("diff", "sess_123") == "/sessions/sess_123/detached/diff"
      assert WindowManager.window_path("dag", "sess_123") == "/sessions/sess_123/detached/dag"

      url = WindowManager.window_url(:terminal, "sess_123")
      assert String.ends_with?(url, "/sessions/sess_123/detached/terminal")
    end

    test "open_window/2 in headless/test mode returns web path fallback" do
      assert {:ok, :web, path} = WindowManager.open_window(:terminal, "sess_abc")
      assert path == "/sessions/sess_abc/detached/terminal"

      assert {:ok, :web, path_diff} = WindowManager.open_window("diff", "sess_abc")
      assert path_diff == "/sessions/sess_abc/detached/diff"

      assert {:error, :unknown_tool} = WindowManager.open_window("invalid_tool", "sess_abc")
    end

    test "hide_window/1 returns ok for known tool" do
      assert WindowManager.hide_window(:terminal) == :ok
      assert WindowManager.hide_window("diff") == :ok
    end

    test "list_windows/0 returns status of all windows" do
      list = WindowManager.list_windows()
      assert is_map(list)
      assert Map.has_key?(list, :terminal)
      assert Map.has_key?(list, :diff)
      assert Map.has_key?(list, :dag)
      assert list.terminal.status in [:running, :stopped]
    end
  end
end

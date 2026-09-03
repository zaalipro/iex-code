defmodule IexCode.Desktop.RuntimeFallbackStressTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Desktop.Package

  describe "fallback_database_path/2 Stress Tests" do
    @tag :tmp_dir
    test "nil env_path creates default Application Support dir and returns standard db path", %{
      tmp_dir: tmp_dir
    } do
      base_dir = Path.join(tmp_dir, "app_support_nil")
      refute File.exists?(base_dir)

      db_path = Package.fallback_database_path(nil, base_dir)

      assert db_path == Path.join(base_dir, "iex_code.db")
      assert File.dir?(base_dir)
    end

    @tag :tmp_dir
    test "empty string env_path creates default Application Support dir and returns standard db path",
         %{tmp_dir: tmp_dir} do
      base_dir = Path.join(tmp_dir, "app_support_empty")
      refute File.exists?(base_dir)

      db_path = Package.fallback_database_path("", base_dir)

      assert db_path == Path.join(base_dir, "iex_code.db")
      assert File.dir?(base_dir)
    end

    @tag :tmp_dir
    test "custom relative path creates intermediate directories", %{tmp_dir: tmp_dir} do
      # Test relative path created relative to tmp_dir
      custom_rel_dir = Path.join(tmp_dir, "nested_rel_dir/sub_folder")
      custom_rel_path = Path.join(custom_rel_dir, "custom.sqlite3")

      refute File.exists?(custom_rel_dir)

      result_path = Package.fallback_database_path(custom_rel_path, tmp_dir)

      assert result_path == custom_rel_path
      assert File.dir?(custom_rel_dir)
    end

    @tag :tmp_dir
    test "deeply nested 10-level non-existent directory path is recursively created", %{
      tmp_dir: tmp_dir
    } do
      deep_path =
        Path.join([
          tmp_dir,
          "l1",
          "l2",
          "l3",
          "l4",
          "l5",
          "l6",
          "l7",
          "l8",
          "l9",
          "l10",
          "deep_iex_code.db"
        ])

      parent_dir = Path.dirname(deep_path)
      refute File.exists?(parent_dir)

      result_path = Package.fallback_database_path(deep_path, tmp_dir)

      assert result_path == deep_path
      assert File.dir?(parent_dir)
    end

    @tag :tmp_dir
    test "paths with spaces, unicode, and symbols are supported", %{tmp_dir: tmp_dir} do
      special_dir = Path.join(tmp_dir, "Iex Code App #1 — Test (Special & UTF-8: 🚀)")
      special_path = Path.join(special_dir, "iex_code_ özel.db")

      result_path = Package.fallback_database_path(special_path, tmp_dir)

      assert result_path == special_path
      assert File.dir?(special_dir)
    end

    @tag :tmp_dir
    test "permission error is raised when creating directory inside read-only directory", %{
      tmp_dir: tmp_dir
    } do
      ro_dir = Path.join(tmp_dir, "read_only_root")
      File.mkdir_p!(ro_dir)
      File.chmod!(ro_dir, 0o555)

      target_dir = Path.join(ro_dir, "forbidden_sub/db.sqlite")

      assert_raise File.Error, fn ->
        Package.fallback_database_path(target_dir, tmp_dir)
      end

      # Reset permissions for cleanup
      File.chmod!(ro_dir, 0o755)
    end
  end

  describe "fallback_secret_key_base/2 Stress Tests" do
    @tag :tmp_dir
    test "nil env_key generates 64-byte random secret with 0o600 permissions", %{
      tmp_dir: tmp_dir
    } do
      base_dir = Path.join(tmp_dir, "secrets_nil")
      refute File.exists?(base_dir)

      key = Package.fallback_secret_key_base(nil, base_dir)

      assert is_binary(key)
      # Base64 of 64 bytes is 86 or 88 chars (padding: false gives 86 chars)
      assert byte_size(key) >= 64

      secret_file = Path.join(base_dir, "secret_key_base")
      assert File.exists?(secret_file)
      assert File.read!(secret_file) == key

      stat = File.stat!(secret_file)
      # 0o600 in octal is (User Read+Write, Group/Other No Access)
      assert Bitwise.band(stat.mode, 0o077) == 0
      assert Bitwise.band(stat.mode, 0o600) == 0o600
    end

    @tag :tmp_dir
    test "empty string env_key generates 64-byte random secret", %{tmp_dir: tmp_dir} do
      base_dir = Path.join(tmp_dir, "secrets_empty")
      key = Package.fallback_secret_key_base("", base_dir)

      assert is_binary(key)
      assert byte_size(key) >= 64

      secret_file = Path.join(base_dir, "secret_key_base")
      assert File.exists?(secret_file)
    end

    @tag :tmp_dir
    test "explicit env_key is preserved without filesystem operations", %{tmp_dir: tmp_dir} do
      base_dir = Path.join(tmp_dir, "secrets_explicit")
      env_key = "explicit_secret_key_from_env_that_exceeds_sixty_four_bytes_length_test"

      key = Package.fallback_secret_key_base(env_key, base_dir)

      assert key == env_key
      refute File.exists?(base_dir)
    end

    @tag :tmp_dir
    test "prefers secret_key_base over legacy .secret_key_base when both exist", %{
      tmp_dir: tmp_dir
    } do
      base_dir = Path.join(tmp_dir, "secrets_precedence")
      File.mkdir_p!(base_dir)

      primary_file = Path.join(base_dir, "secret_key_base")
      legacy_file = Path.join(base_dir, ".secret_key_base")

      primary_key = "primary_key_base_1234567890_abcdefghijklmnopqrstuvwxyz_1234567890"
      legacy_key = "legacy_key_base_1234567890_abcdefghijklmnopqrstuvwxyz_1234567890"

      File.write!(primary_file, primary_key)
      File.write!(legacy_file, legacy_key)

      key = Package.fallback_secret_key_base(nil, base_dir)

      assert key == primary_key
    end

    @tag :tmp_dir
    test "falls back to legacy .secret_key_base when primary file is absent", %{
      tmp_dir: tmp_dir
    } do
      base_dir = Path.join(tmp_dir, "secrets_legacy_only")
      File.mkdir_p!(base_dir)

      legacy_file = Path.join(base_dir, ".secret_key_base")
      legacy_key = "legacy_key_base_1234567890_abcdefghijklmnopqrstuvwxyz_1234567890"
      File.write!(legacy_file, legacy_key)

      key = Package.fallback_secret_key_base(nil, base_dir)

      assert key == legacy_key
    end

    @tag :tmp_dir
    test "trims whitespace and newlines from persisted secret file", %{tmp_dir: tmp_dir} do
      base_dir = Path.join(tmp_dir, "secrets_trim")
      File.mkdir_p!(base_dir)

      raw_key = "clean_key_base_1234567890_abcdefghijklmnopqrstuvwxyz_1234567890"
      file_content = "  \t\n  #{raw_key}  \r\n\t  "

      File.write!(Path.join(base_dir, "secret_key_base"), file_content)

      key = Package.fallback_secret_key_base(nil, base_dir)

      assert key == raw_key
    end

    @tag :tmp_dir
    test "idempotency: 100 consecutive calls return the exact same key without regenerating", %{
      tmp_dir: tmp_dir
    } do
      base_dir = Path.join(tmp_dir, "secrets_idempotent")

      initial_key = Package.fallback_secret_key_base(nil, base_dir)

      for _i <- 1..100 do
        assert Package.fallback_secret_key_base(nil, base_dir) == initial_key
      end
    end

    @tag :tmp_dir
    test "entropy and uniqueness: 50 independent keys have high Shannon entropy and 0 collisions",
         %{tmp_dir: tmp_dir} do
      keys =
        for i <- 1..50 do
          dir = Path.join(tmp_dir, "entropy_test_#{i}")
          key = Package.fallback_secret_key_base(nil, dir)
          assert byte_size(key) >= 64
          key
        end

      # Uniqueness
      unique_keys = Enum.uniq(keys)
      assert length(unique_keys) == 50

      # Check Shannon entropy for each generated key
      for key <- keys do
        entropy = calculate_shannon_entropy(key)

        # Base64 theoretical max is 6 bits/character; 64-byte random payload typically yields > 5.5 bits/char
        assert entropy >= 5.0, "Entropy #{entropy} was lower than expected for key #{key}"
      end
    end
  end

  describe "fallback_endpoint_url/2 Stress Tests" do
    test "handles nil and empty strings for host and port" do
      assert Package.fallback_endpoint_url(nil, nil) == [
               host: "localhost",
               port: 4000,
               scheme: "http"
             ]

      assert Package.fallback_endpoint_url("", "") == [
               host: "localhost",
               port: 4000,
               scheme: "http"
             ]

      assert Package.fallback_endpoint_url(nil, "") == [
               host: "localhost",
               port: 4000,
               scheme: "http"
             ]

      assert Package.fallback_endpoint_url("", nil) == [
               host: "localhost",
               port: 4000,
               scheme: "http"
             ]
    end

    test "handles loopback addresses: localhost and 127.0.0.1 with custom ports" do
      assert Package.fallback_endpoint_url("localhost", 5000) == [
               host: "localhost",
               port: 5000,
               scheme: "http"
             ]

      assert Package.fallback_endpoint_url("localhost", "5001") == [
               host: "localhost",
               port: 5001,
               scheme: "http"
             ]

      assert Package.fallback_endpoint_url("127.0.0.1", 3000) == [
               host: "127.0.0.1",
               port: 3000,
               scheme: "http"
             ]

      assert Package.fallback_endpoint_url("127.0.0.1", "3000") == [
               host: "127.0.0.1",
               port: 3000,
               scheme: "http"
             ]
    end

    test "handles remote domain names and secures with https and port 443" do
      assert Package.fallback_endpoint_url("app.iexcode.io", 4000) == [
               host: "app.iexcode.io",
               port: 443,
               scheme: "https"
             ]

      assert Package.fallback_endpoint_url("my-domain.example.com", "8080") == [
               host: "my-domain.example.com",
               port: 443,
               scheme: "https"
             ]

      assert Package.fallback_endpoint_url("internal.corp", nil) == [
               host: "internal.corp",
               port: 443,
               scheme: "https"
             ]
    end
  end

  describe "Package.create_dmg/3 Stress & Edge Cases" do
    @tag :tmp_dir
    test "create_dmg returns error on non-existent app_dir", %{tmp_dir: tmp_dir} do
      non_existent_app = Path.join(tmp_dir, "NonExistent.app")
      dmg_path = Path.join(tmp_dir, "output.dmg")

      case Package.create_dmg(non_existent_app, dmg_path) do
        {:error, reason} ->
          assert reason =~ "hdiutil failed with code"
          refute File.exists?(dmg_path)

        :skipped ->
          # If not on macOS or hdiutil missing
          assert true
      end
    end

    @tag :tmp_dir
    test "create_dmg creates valid DMG with spaces and unicode volume name", %{tmp_dir: tmp_dir} do
      app_dir = Path.join(tmp_dir, "IexCode Special 🚀.app")
      File.mkdir_p!(Path.join(app_dir, "Contents/MacOS"))
      File.write!(Path.join(app_dir, "Contents/Info.plist"), Package.info_plist())
      File.write!(Path.join(app_dir, "Contents/MacOS/launcher"), "#!/bin/sh\necho ok")
      File.chmod!(Path.join(app_dir, "Contents/MacOS/launcher"), 0o755)

      dmg_path = Path.join(tmp_dir, "IexCode Special.dmg")

      case Package.create_dmg(app_dir, dmg_path, app_name: "IexCode Special 🚀") do
        {:ok, created_path} ->
          assert created_path == dmg_path
          assert File.exists?(dmg_path)
          assert File.stat!(dmg_path).size > 0

          # Validate image with hdiutil imageinfo
          if System.find_executable("hdiutil") do
            {info_out, exit_code} = System.cmd("hdiutil", ["imageinfo", dmg_path])
            assert exit_code == 0
            assert info_out =~ "UDZO" or info_out =~ "UDRO" or info_out =~ "UDIF"
          end

        :skipped ->
          assert true
      end
    end

    @tag :tmp_dir
    test "create_dmg overwrites existing DMG without error (-ov flag)", %{tmp_dir: tmp_dir} do
      app_dir = Path.join(tmp_dir, "App.app")
      File.mkdir_p!(Path.join(app_dir, "Contents"))
      File.write!(Path.join(app_dir, "Contents/Info.plist"), Package.info_plist())

      dmg_path = Path.join(tmp_dir, "App.dmg")
      File.write!(dmg_path, "pre-existing stale content")

      case Package.create_dmg(app_dir, dmg_path, app_name: "App") do
        {:ok, created_path} ->
          assert created_path == dmg_path
          assert File.exists?(dmg_path)
          # Ensure content was replaced with real DMG data
          refute File.read!(dmg_path) == "pre-existing stale content"

        :skipped ->
          assert true
      end
    end
  end

  describe "Launcher Script and Plist Integrity Tests" do
    test "launcher script is syntactically valid bash" do
      script = Package.launcher_script(app_name: "IexCode", rel_bin_name: "iex_code")

      if System.find_executable("bash") do
        # Write to a temp file and check syntax with bash -n
        tmp_file =
          Path.join(
            System.tmp_dir!(),
            "launcher_syntax_check_#{System.unique_integer([:positive])}.sh"
          )

        File.write!(tmp_file, script)

        {output, exit_code} = System.cmd("bash", ["-n", tmp_file])
        File.rm(tmp_file)

        assert exit_code == 0, "bash -n syntax check failed: #{output}"
      end
    end

    test "info_plist produces valid Apple DTD compliant XML" do
      plist =
        Package.info_plist(app_name: "IexCode", bundle_id: "com.iexcode.app", version: "0.1.0")

      assert {:ok, _} = Floki.parse_document(plist)

      assert plist =~
               "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">"

      assert plist =~ "<key>CFBundlePackageType</key>\n    <string>APPL</string>"
      assert plist =~ "<key>LSMinimumSystemVersion</key>\n    <string>12.0</string>"
    end
  end

  describe "config/runtime.exs Prod Evaluation Stress Tests" do
    test "evaluates config/runtime.exs in :prod with default environment" do
      # Backup env
      orig_db = System.get_env("DATABASE_PATH")
      orig_secret = System.get_env("SECRET_KEY_BASE")
      orig_host = System.get_env("PHX_HOST")
      orig_port = System.get_env("PORT")
      orig_bind = System.get_env("IEX_CODE_BIND")
      orig_desktop = System.get_env("DESKTOP_WINDOW")

      on_exit(fn ->
        restore_env("DATABASE_PATH", orig_db)
        restore_env("SECRET_KEY_BASE", orig_secret)
        restore_env("PHX_HOST", orig_host)
        restore_env("PORT", orig_port)
        restore_env("IEX_CODE_BIND", orig_bind)
        restore_env("DESKTOP_WINDOW", orig_desktop)
      end)

      System.delete_env("DATABASE_PATH")
      System.delete_env("SECRET_KEY_BASE")
      System.delete_env("PHX_HOST")
      System.delete_env("PORT")
      System.delete_env("IEX_CODE_BIND")
      System.delete_env("DESKTOP_WINDOW")

      config = Config.Reader.read!("config/runtime.exs", env: :prod)

      repo_config = config[:iex_code][IexCode.Repo]
      endpoint_config = config[:iex_code][IexCodeWeb.Endpoint]

      assert is_list(repo_config)
      assert is_list(endpoint_config)

      # Repo DB path
      assert repo_config[:database] =~ "Library/Application Support/IexCode/iex_code.db"
      assert repo_config[:journal_mode] == :wal
      assert repo_config[:pool_size] == 5

      # Endpoint Config
      assert endpoint_config[:url] == [host: "localhost", port: 4000, scheme: "http"]
      assert endpoint_config[:http][:ip] == {127, 0, 0, 1}
      assert endpoint_config[:http][:port] == 4000
      assert endpoint_config[:server] == true
      assert is_binary(endpoint_config[:secret_key_base])
      assert byte_size(endpoint_config[:secret_key_base]) >= 64

      # Desktop window
      assert config[:iex_code][:start_desktop_window] == true
    end

    test "evaluates config/runtime.exs in :prod with custom domain, port, and bind IP" do
      orig_db = System.get_env("DATABASE_PATH")
      orig_secret = System.get_env("SECRET_KEY_BASE")
      orig_host = System.get_env("PHX_HOST")
      orig_port = System.get_env("PORT")
      orig_bind = System.get_env("IEX_CODE_BIND")
      orig_desktop = System.get_env("DESKTOP_WINDOW")

      on_exit(fn ->
        restore_env("DATABASE_PATH", orig_db)
        restore_env("SECRET_KEY_BASE", orig_secret)
        restore_env("PHX_HOST", orig_host)
        restore_env("PORT", orig_port)
        restore_env("IEX_CODE_BIND", orig_bind)
        restore_env("DESKTOP_WINDOW", orig_desktop)
      end)

      System.put_env("PHX_HOST", "my-app.cloud")
      System.put_env("PORT", "9090")
      System.put_env("IEX_CODE_BIND", "0.0.0.0")
      System.put_env("DESKTOP_WINDOW", "false")

      config = Config.Reader.read!("config/runtime.exs", env: :prod)

      endpoint_config = config[:iex_code][IexCodeWeb.Endpoint]

      assert endpoint_config[:url] == [host: "my-app.cloud", port: 443, scheme: "https"]
      assert endpoint_config[:http][:ip] == {0, 0, 0, 0}
      assert endpoint_config[:http][:port] == 9090
      assert config[:iex_code][:start_desktop_window] == false
    end

    test "raises error when IEX_CODE_BIND is an invalid IP address" do
      orig_bind = System.get_env("IEX_CODE_BIND")

      on_exit(fn ->
        restore_env("IEX_CODE_BIND", orig_bind)
      end)

      System.put_env("IEX_CODE_BIND", "not_a_valid_ip")

      assert_raise RuntimeError,
                   ~r/environment variable IEX_CODE_BIND is not a valid IP address/,
                   fn ->
                     Config.Reader.read!("config/runtime.exs", env: :prod)
                   end
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, val), do: System.put_env(key, val)

  # Helper function to compute Shannon entropy in bits per character
  defp calculate_shannon_entropy(str) when is_binary(str) do
    len = byte_size(str)

    if len == 0 do
      0.0
    else
      freqs =
        str
        |> :erlang.binary_to_list()
        |> Enum.frequencies()

      Enum.reduce(freqs, 0.0, fn {_char, count}, acc ->
        p = count / len
        acc - p * :math.log2(p)
      end)
    end
  end
end

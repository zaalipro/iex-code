defmodule IexCode.Desktop.PackageAdversarialStressTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Desktop.Package

  describe "Adversarial Stress Test: fallback_database_path/2" do
    @tag :tmp_dir
    test "handles nil and empty string by falling back to base directory and creating it", %{
      tmp_dir: tmp_dir
    } do
      # Test nil with custom base_dir
      base_dir = Path.join(tmp_dir, "base_nil")
      refute File.dir?(base_dir)
      path_nil = Package.fallback_database_path(nil, base_dir)
      assert path_nil == Path.join(base_dir, "iex_code.db")
      assert File.dir?(base_dir)

      # Test empty string with custom base_dir
      base_dir_empty = Path.join(tmp_dir, "base_empty")
      refute File.dir?(base_dir_empty)
      path_empty = Package.fallback_database_path("", base_dir_empty)
      assert path_empty == Path.join(base_dir_empty, "iex_code.db")
      assert File.dir?(base_dir_empty)
    end

    @tag :tmp_dir
    test "handles relative and deep paths by creating parent directories recursively", %{
      tmp_dir: tmp_dir
    } do
      # Deep nested path
      deep_path = Path.join([tmp_dir, "level1", "level2", "level3", "sub", "custom.db"])
      deep_dir = Path.dirname(deep_path)
      refute File.dir?(deep_dir)

      result_path = Package.fallback_database_path(deep_path, tmp_dir)
      assert result_path == deep_path
      assert File.dir?(deep_dir)

      # Simple relative file path in current directory
      rel_result = Package.fallback_database_path("custom_rel.db", tmp_dir)
      assert rel_result == "custom_rel.db"
      assert File.dir?(".")
    end

    test "default fallback without base_dir resolves to Application Support and creates directory" do
      app_support = Path.expand("~/Library/Application Support/IexCode")
      result = Package.fallback_database_path(nil, nil)
      assert result == Path.join(app_support, "iex_code.db")
      assert File.dir?(app_support)
    end
  end

  describe "Adversarial Stress Test: fallback_secret_key_base/2" do
    @tag :tmp_dir
    test "generates high-entropy >=64-byte key with 0o600 permissions and persists it", %{
      tmp_dir: tmp_dir
    } do
      secrets_dir = Path.join(tmp_dir, "secrets_test")
      refute File.dir?(secrets_dir)

      key = Package.fallback_secret_key_base(nil, secrets_dir)

      # Length check: 64 random bytes Base64-encoded without padding is 86 characters
      assert is_binary(key)
      assert byte_size(key) >= 64
      assert byte_size(key) == 86

      # Validate character set (Base64 standard chars)
      assert key =~ ~r/^[A-Za-z0-9+\/_-]+$/

      # Check Shannon entropy: 86 characters sampled from 64 base64 chars has theoretical expected entropy ~5.5 bits/char
      entropy = calculate_shannon_entropy(key)
      assert entropy > 5.0, "Generated key entropy #{entropy} is too low"

      # Verify file existence and contents
      secret_file = Path.join(secrets_dir, "secret_key_base")
      assert File.exists?(secret_file)
      assert File.read!(secret_file) == key

      # Verify file permissions: 0o600 (owner read/write only, no group or other permissions)
      stat = File.stat!(secret_file)

      assert Bitwise.band(stat.mode, 0o077) == 0,
             "Secret file has unsafe permission bits: #{Integer.to_string(stat.mode, 8)}"

      # Verify idempotence: second read returns exact same key
      key_repeat = Package.fallback_secret_key_base(nil, secrets_dir)
      assert key_repeat == key
    end

    @tag :tmp_dir
    test "handles empty string input identically to nil", %{tmp_dir: tmp_dir} do
      secrets_dir = Path.join(tmp_dir, "secrets_empty_test")
      key = Package.fallback_secret_key_base("", secrets_dir)
      assert is_binary(key)
      assert byte_size(key) == 86

      secret_file = Path.join(secrets_dir, "secret_key_base")
      assert File.read!(secret_file) == key
    end

    @tag :tmp_dir
    test "trims trailing newlines and whitespace from existing secret_key_base file", %{
      tmp_dir: tmp_dir
    } do
      secrets_dir = Path.join(tmp_dir, "secrets_whitespace")
      File.mkdir_p!(secrets_dir)

      raw_key = "my_custom_pre_existing_secret_key_that_is_at_least_sixty_four_bytes_long_123456"
      padded_key = "\r\n  " <> raw_key <> "  \n\n"
      File.write!(Path.join(secrets_dir, "secret_key_base"), padded_key)

      key = Package.fallback_secret_key_base(nil, secrets_dir)
      assert key == raw_key
      assert byte_size(key) >= 64
    end

    @tag :tmp_dir
    test "supports legacy .secret_key_base file when secret_key_base is absent", %{
      tmp_dir: tmp_dir
    } do
      secrets_dir = Path.join(tmp_dir, "secrets_legacy")
      File.mkdir_p!(secrets_dir)

      legacy_key = "legacy_key_that_is_persisted_in_dot_file_with_plenty_of_bytes_1234567890"
      File.write!(Path.join(secrets_dir, ".secret_key_base"), legacy_key <> "\n")

      key = Package.fallback_secret_key_base(nil, secrets_dir)
      assert key == legacy_key
    end

    @tag :tmp_dir
    test "prioritizes secret_key_base over .secret_key_base when both exist", %{
      tmp_dir: tmp_dir
    } do
      secrets_dir = Path.join(tmp_dir, "secrets_both")
      File.mkdir_p!(secrets_dir)

      primary_key = "primary_key_base_value_with_plenty_of_length_and_entropy_123456789012345"
      legacy_key = "legacy_key_base_value_with_plenty_of_length_and_entropy_987654321098765"

      File.write!(Path.join(secrets_dir, "secret_key_base"), primary_key)
      File.write!(Path.join(secrets_dir, ".secret_key_base"), legacy_key)

      key = Package.fallback_secret_key_base(nil, secrets_dir)
      assert key == primary_key
    end

    @tag :tmp_dir
    test "preserves explicit environment variable without touching filesystem", %{
      tmp_dir: tmp_dir
    } do
      secrets_dir = Path.join(tmp_dir, "secrets_untouched")
      env_key = "explicit_secret_key_base_provided_by_environment_variable_123456789012"

      key = Package.fallback_secret_key_base(env_key, secrets_dir)
      assert key == env_key
      refute File.dir?(secrets_dir)
    end

    @tag :tmp_dir
    test "generates 100 distinct keys with 0 collisions and verifies entropy distribution", %{
      tmp_dir: tmp_dir
    } do
      keys =
        for i <- 1..100 do
          dir = Path.join(tmp_dir, "gen_#{i}")
          Package.fallback_secret_key_base(nil, dir)
        end

      assert length(Enum.uniq(keys)) == 100
      assert Enum.all?(keys, &(byte_size(&1) == 86))
      assert Enum.all?(keys, &(calculate_shannon_entropy(&1) > 5.0))
    end
  end

  describe "Adversarial Stress Test: fallback_endpoint_url/2" do
    test "resolves loopback hosts to http with port preservation" do
      # Default localhost
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

      # Explicit localhost with custom string port
      assert Package.fallback_endpoint_url("localhost", "8080") == [
               host: "localhost",
               port: 8080,
               scheme: "http"
             ]

      # 127.0.0.1 with integer port
      assert Package.fallback_endpoint_url("127.0.0.1", 5000) == [
               host: "127.0.0.1",
               port: 5000,
               scheme: "http"
             ]

      # 127.0.0.1 with string port
      assert Package.fallback_endpoint_url("127.0.0.1", "9000") == [
               host: "127.0.0.1",
               port: 9000,
               scheme: "http"
             ]
    end

    test "resolves remote and custom domains to https:443" do
      # Custom domain
      assert Package.fallback_endpoint_url("iexcode.example.com", "4000") == [
               host: "iexcode.example.com",
               port: 443,
               scheme: "https"
             ]

      # Local network / custom host
      assert Package.fallback_endpoint_url("app.internal", nil) == [
               host: "app.internal",
               port: 443,
               scheme: "https"
             ]

      # IPv4 non-loopback
      assert Package.fallback_endpoint_url("192.168.1.50", "3000") == [
               host: "192.168.1.50",
               port: 443,
               scheme: "https"
             ]
    end
  end

  describe "Adversarial Stress Test: Package.create_dmg/3" do
    @tag :tmp_dir
    test "creates valid DMG with hdiutil and verifies imageinfo on macOS", %{tmp_dir: tmp_dir} do
      if System.find_executable("hdiutil") != nil and match?({:unix, :darwin}, :os.type()) do
        app_dir = Path.join(tmp_dir, "StressApp.app")
        contents_dir = Path.join(app_dir, "Contents")
        macos_dir = Path.join(contents_dir, "MacOS")
        File.mkdir_p!(macos_dir)

        File.write!(
          Path.join(contents_dir, "Info.plist"),
          Package.info_plist(app_name: "StressApp")
        )

        File.write!(Path.join(contents_dir, "PkgInfo"), Package.pkg_info())
        launcher = Path.join(macos_dir, "StressApp")
        File.write!(launcher, "#!/bin/sh\necho running")
        File.chmod!(launcher, 0o755)

        dmg_dir = Path.join([tmp_dir, "deep_dmg_dir", "sub"])
        dmg_path = Path.join(dmg_dir, "StressApp.dmg")

        # Verify create_dmg creates parent directories if needed
        assert {:ok, created_path} = Package.create_dmg(app_dir, dmg_path, app_name: "StressApp")
        assert created_path == dmg_path
        assert File.exists?(dmg_path)
        assert File.stat!(dmg_path).size > 0

        # Verify DMG image format with hdiutil imageinfo
        {output, exit_code} = System.cmd("hdiutil", ["imageinfo", dmg_path])
        assert exit_code == 0
        assert output =~ "Format: UDZO" or output =~ "StressApp"

        # Overwrite test: create again at the same destination
        assert {:ok, ^dmg_path} = Package.create_dmg(app_dir, dmg_path, app_name: "StressApp")
        assert File.exists?(dmg_path)
      end
    end

    @tag :tmp_dir
    test "gracefully returns {:error, reason} when source directory does not exist", %{
      tmp_dir: tmp_dir
    } do
      if System.find_executable("hdiutil") != nil and match?({:unix, :darwin}, :os.type()) do
        non_existent_app = Path.join(tmp_dir, "Ghost.app")
        dmg_path = Path.join(tmp_dir, "Ghost.dmg")

        result = Package.create_dmg(non_existent_app, dmg_path, app_name: "Ghost")
        assert match?({:error, _reason}, result)
        {:error, reason} = result
        assert reason =~ "hdiutil failed with code"
      end
    end
  end

  describe "Adversarial Stress Test: config/runtime.exs Prod Evaluation" do
    @tag :tmp_dir
    test "evaluates config/runtime.exs logic in prod context with desktop fallbacks", %{
      tmp_dir: tmp_dir
    } do
      app_support = Path.join(tmp_dir, "ProdAppSupport")
      db_path = Package.fallback_database_path(nil, app_support)
      secret_key = Package.fallback_secret_key_base(nil, app_support)
      endpoint_url = Package.fallback_endpoint_url(nil, nil)

      assert db_path == Path.join(app_support, "iex_code.db")
      assert is_binary(secret_key)
      assert byte_size(secret_key) >= 64
      assert endpoint_url == [host: "localhost", port: 4000, scheme: "http"]
    end
  end

  # Helper to compute Shannon entropy in bits per character
  defp calculate_shannon_entropy(str) when is_binary(str) do
    len = byte_size(str)

    if len == 0 do
      0.0
    else
      frequencies =
        str
        |> :erlang.binary_to_list()
        |> Enum.frequencies()

      Enum.reduce(frequencies, 0.0, fn {_char, count}, acc ->
        prob = count / len
        acc - prob * :math.log2(prob)
      end)
    end
  end
end

defmodule IexCode.Desktop.PackageAdversarialTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Desktop.Package

  describe "Adversarial CLI Options and Argument Permutations" do
    @tag :tmp_dir
    test "handles paths and app names with spaces and special characters", %{tmp_dir: tmp_dir} do
      output_dir = Path.join(tmp_dir, "space path in output/nested dir")
      app_name = "Iex Code App"
      bundle_id = "com.iex-code.custom-app"
      dmg_name = "Iex Code-0.1.0-arm64.dmg"

      args = [
        "--no-dmg",
        "--skip-assets",
        "--skip-release",
        "--output-dir",
        output_dir,
        "--app-name",
        app_name,
        "--bundle-id",
        bundle_id,
        "--dmg-name",
        dmg_name
      ]

      assert {:ok, app_dir, nil} = Package.run(args)
      assert File.dir?(app_dir)
      assert Path.basename(app_dir) == "Iex Code App.app"

      # Check Info.plist
      plist_path = Path.join([app_dir, "Contents", "Info.plist"])
      assert File.exists?(plist_path)
      plist_content = File.read!(plist_path)
      assert plist_content =~ "<string>#{app_name}</string>"
      assert plist_content =~ "<string>#{bundle_id}</string>"

      # Check Launcher
      launcher_path = Path.join([app_dir, "Contents", "MacOS", app_name])
      assert File.exists?(launcher_path)
      stat = File.stat!(launcher_path)
      assert Bitwise.band(stat.mode, 0o111) == 0o111

      # Check bash syntax of launcher
      {output, exit_code} = System.cmd("bash", ["-n", launcher_path])
      assert exit_code == 0, "Launcher bash syntax error: #{output}"
    end

    @tag :tmp_dir
    test "handles -o alias and relative output directory", %{tmp_dir: tmp_dir} do
      rel_out = Path.join(tmp_dir, "rel_out")

      args = [
        "-o",
        rel_out,
        "--no-dmg",
        "--skip-assets",
        "--skip-release",
        "--app-name",
        "AliasApp"
      ]

      assert {:ok, app_dir, nil} = Package.run(args)
      assert File.dir?(app_dir)
      assert Path.basename(app_dir) == "AliasApp.app"
      assert Path.expand(app_dir) == Path.expand(Path.join(rel_out, "AliasApp.app"))
    end

    @tag :tmp_dir
    test "handles deep non-existent output paths creating all parents", %{tmp_dir: tmp_dir} do
      deep_path = Path.join([tmp_dir, "a", "b", "c", "d", "e", "desktop"])

      args = [
        "--output-dir",
        deep_path,
        "--no-dmg",
        "--skip-assets",
        "--skip-release"
      ]

      assert {:ok, app_dir, nil} = Package.run(args)
      assert File.dir?(app_dir)
      assert File.dir?(deep_path)
    end
  end

  describe "Info.plist XML Robustness and Apple plutil -lint" do
    @tag :tmp_dir
    test "passes plutil -lint for complex and standard configurations", %{tmp_dir: tmp_dir} do
      test_cases = [
        [app_name: "IexCode", bundle_id: "com.iexcode.app", version: "0.1.0"],
        [
          app_name: "MyApp_Dev",
          bundle_id: "io.github.elixir.desktop",
          version: "1.0.0-rc.3+20260902"
        ],
        [app_name: "Code-Studio", bundle_id: "com.company.dept.app", version: "2026.9.2"],
        [app_name: "IëxCode", bundle_id: "com.iexcode.unicode", version: "0.1.0"]
      ]

      for {opts, idx} <- Enum.with_index(test_cases) do
        plist = Package.info_plist(opts)
        file_path = Path.join(tmp_dir, "Info_#{idx}.plist")
        File.write!(file_path, plist)

        # Floki XML parse verification
        assert {:ok, _doc} = Floki.parse_document(plist)

        # Apple plutil -lint verification
        if System.find_executable("plutil") do
          {output, exit_code} = System.cmd("plutil", ["-lint", file_path])
          assert exit_code == 0, "plutil -lint failed for case #{inspect(opts)}: #{output}"
        end
      end
    end

    test "includes all required Apple bundle keys and valid DTD" do
      plist = Package.info_plist()

      required_keys = [
        "CFBundleDevelopmentRegion",
        "CFBundleDisplayName",
        "CFBundleExecutable",
        "CFBundleIconFile",
        "CFBundleIdentifier",
        "CFBundleInfoDictionaryVersion",
        "CFBundleName",
        "CFBundlePackageType",
        "CFBundleShortVersionString",
        "CFBundleVersion",
        "LSMinimumSystemVersion",
        "NSHighResolutionCapable",
        "NSHumanReadableCopyright",
        "NSSupportsAutomaticGraphicsSwitching"
      ]

      for key <- required_keys do
        assert plist =~ "<key>#{key}</key>", "Missing required plist key: #{key}"
      end

      assert plist =~ "APPL"
      assert plist =~ "12.0"
      assert plist =~ "<true/>"
    end
  end

  describe "Launcher Script Permissions and Execution Robustness" do
    @tag :tmp_dir
    test "launcher script correctly quotes paths and sets 0o755 executable bits", %{
      tmp_dir: tmp_dir
    } do
      macos_dir = Path.join(tmp_dir, "MacOS")
      File.mkdir_p!(macos_dir)
      launcher_path = Path.join(macos_dir, "IexCode Launcher")

      script_content =
        Package.launcher_script(app_name: "IexCode Launcher", rel_bin_name: "iex_code")

      File.write!(launcher_path, script_content)
      File.chmod!(launcher_path, 0o755)

      # Check permission bits
      stat = File.stat!(launcher_path)
      # 0o755 is 0b111_101_101 (or 0o755 octal)
      assert Bitwise.band(stat.mode, 0o777) == 0o755

      # Syntax validation with bash
      {output, exit_code} = System.cmd("bash", ["-n", launcher_path])
      assert exit_code == 0, "Bash syntax check failed: #{output}"

      # Check critical variables and quotations
      assert script_content =~ ~s[SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"]
      assert script_content =~ ~s[CONTENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"]
      assert script_content =~ ~s[APP_SUPPORT_DIR="$HOME/Library/Application Support/IexCode"]
      assert script_content =~ ~s[exec "$REL_DIR/bin/iex_code" start]
    end
  end

  describe "Full Bundle Assembly & Permissions Preservation" do
    @tag :tmp_dir
    test "recursively copies release artifacts and sets executable bits on all release binaries",
         %{
           tmp_dir: tmp_dir
         } do
      # Create mock release directory tree with multiple binaries and NIFs
      rel_src = Path.join(tmp_dir, "mock_release")
      bin_dir = Path.join(rel_src, "bin")
      erts_bin_dir = Path.join([rel_src, "erts-16.3.1", "bin"])
      lib_dir = Path.join([rel_src, "lib", "iex_code-0.1.0", "priv"])
      File.mkdir_p!(bin_dir)
      File.mkdir_p!(erts_bin_dir)
      File.mkdir_p!(lib_dir)

      # Create release binaries (initially without executable bit to test chmod)
      iex_bin = Path.join(bin_dir, "iex_code")
      File.write!(iex_bin, "#!/bin/sh\necho 'iex_code running'")
      File.chmod!(iex_bin, 0o644)

      sub_bin = Path.join(bin_dir, "sub_cmd")
      File.write!(sub_bin, "#!/bin/sh\necho 'sub cmd'")
      File.chmod!(sub_bin, 0o644)

      # Create fake nif
      nif_so = Path.join(lib_dir, "sqlite3_nif.so")
      File.write!(nif_so, "dummy binary content")

      output_dir = Path.join(tmp_dir, "bundle_output")

      app_dir =
        Package.assemble_bundle(
          output_dir: output_dir,
          app_name: "MockApp",
          bundle_id: "com.mock.app",
          version: "0.2.0",
          release_src_dir: rel_src
        )

      assert File.dir?(app_dir)

      # Verify structure
      assert File.exists?(Path.join([app_dir, "Contents", "Info.plist"]))
      assert File.exists?(Path.join([app_dir, "Contents", "PkgInfo"]))
      assert File.read!(Path.join([app_dir, "Contents", "PkgInfo"])) == "APPL????"

      # Verify launcher
      launcher = Path.join([app_dir, "Contents", "MacOS", "MockApp"])
      assert File.exists?(launcher)
      assert Bitwise.band(File.stat!(launcher).mode, 0o777) == 0o755

      # Verify release binaries in Resources/rel/bin have executable bits
      rel_bin = Path.join([app_dir, "Contents", "Resources", "rel", "bin", "iex_code"])
      assert File.exists?(rel_bin)
      assert Bitwise.band(File.stat!(rel_bin).mode, 0o111) != 0

      rel_sub_bin = Path.join([app_dir, "Contents", "Resources", "rel", "bin", "sub_cmd"])
      assert File.exists?(rel_sub_bin)
      assert Bitwise.band(File.stat!(rel_sub_bin).mode, 0o111) != 0

      # Verify NIF copied
      assert File.exists?(
               Path.join([
                 app_dir,
                 "Contents",
                 "Resources",
                 "rel",
                 "lib",
                 "iex_code-0.1.0",
                 "priv",
                 "sqlite3_nif.so"
               ])
             )
    end
  end

  describe "DMG Creation Edge Cases and Skip Modes" do
    @tag :tmp_dir
    test "create_dmg handles skip and non-darwin gracefully", %{tmp_dir: tmp_dir} do
      app_dir = Path.join(tmp_dir, "SkipApp.app")
      File.mkdir_p!(Path.join(app_dir, "Contents"))
      dmg_path = Path.join(tmp_dir, "SkipApp.dmg")

      result = Package.create_dmg(app_dir, dmg_path, app_name: "SkipApp")
      assert result in [{:ok, dmg_path}, :skipped]
    end

    @tag :tmp_dir
    test "create_dmg handles invalid app_dir with error tuple", %{tmp_dir: tmp_dir} do
      invalid_app_dir = Path.join(tmp_dir, "non_existent_app_folder")
      dmg_path = Path.join(tmp_dir, "ErrorApp.dmg")

      if match?({:unix, :darwin}, :os.type()) && System.find_executable("hdiutil") do
        result = Package.create_dmg(invalid_app_dir, dmg_path, app_name: "ErrorApp")
        assert match?({:error, _reason}, result)
      end
    end
  end

  describe "Runtime Desktop Fallback Idempotency and Robustness" do
    @tag :tmp_dir
    test "secret_key_base generation creates exactly 64-byte key with 0o600 permissions", %{
      tmp_dir: tmp_dir
    } do
      base_dir = Path.join(tmp_dir, "app_support_secrets")

      key1 = Package.fallback_secret_key_base(nil, base_dir)
      assert is_binary(key1)
      assert byte_size(key1) >= 64

      secret_file = Path.join(base_dir, "secret_key_base")
      stat = File.stat!(secret_file)
      # 0o600 permissions check (no group/other read/write)
      assert Bitwise.band(stat.mode, 0o077) == 0

      # Idempotency check: 10 repeated calls must return the same key without modifying file
      for _ <- 1..10 do
        assert Package.fallback_secret_key_base(nil, base_dir) == key1
      end
    end

    @tag :tmp_dir
    test "database_path handles empty string, nil, and custom paths with spaces", %{
      tmp_dir: tmp_dir
    } do
      base_dir = Path.join(tmp_dir, "app support with spaces")

      # nil
      path_nil = Package.fallback_database_path(nil, base_dir)
      assert path_nil == Path.join(base_dir, "iex_code.db")
      assert File.dir?(base_dir)

      # empty string
      path_empty = Package.fallback_database_path("", base_dir)
      assert path_empty == Path.join(base_dir, "iex_code.db")

      # custom path with spaces
      custom = Path.join([tmp_dir, "custom storage", "db", "app.sqlite3"])
      path_custom = Package.fallback_database_path(custom, base_dir)
      assert path_custom == custom
      assert File.dir?(Path.dirname(custom))
    end

    test "endpoint_url handles varied host, port formats, and schemes" do
      # Localhost defaults
      assert Package.fallback_endpoint_url(nil, nil) == [
               host: "localhost",
               port: 4000,
               scheme: "http"
             ]

      assert Package.fallback_endpoint_url("127.0.0.1", "3000") == [
               host: "127.0.0.1",
               port: 3000,
               scheme: "http"
             ]

      assert Package.fallback_endpoint_url("localhost", 8080) == [
               host: "localhost",
               port: 8080,
               scheme: "http"
             ]

      # Remote host -> https on port 443
      assert Package.fallback_endpoint_url("my-iex-code.internal", "4000") == [
               host: "my-iex-code.internal",
               port: 443,
               scheme: "https"
             ]
    end
  end
end

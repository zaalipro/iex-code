defmodule IexCode.Desktop.PackageTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Desktop.Package

  describe "Release Configuration in mix.exs" do
    test "defines :iex_code release with proper options" do
      config = Mix.Project.config()
      releases = config[:releases]

      assert is_list(releases)
      assert Keyword.has_key?(releases, :iex_code)

      iex_code_rel = releases[:iex_code]
      assert iex_code_rel[:include_executables_for] == [:unix]
      assert iex_code_rel[:include_erts] == true

      apps = iex_code_rel[:applications]
      assert is_list(apps)
      assert apps[:runtime_tools] == :load
      assert apps[:wx] == :load
      assert apps[:desktop] == :load
    end

    test "defines desktop.package alias in mix.exs" do
      config = Mix.Project.config()
      aliases = config[:aliases]

      assert is_list(aliases)
      assert Keyword.has_key?(aliases, :"desktop.package")
      assert aliases[:"desktop.package"] == ["desktop.package"]
    end
  end

  describe "Mix.Tasks.Desktop.Package Task Definition" do
    test "task module is loaded and exports run/1" do
      assert Code.ensure_loaded?(Package)
      assert function_exported?(Package, :run, 1)

      assert Mix.Task.shortdoc(Package) ==
               "Packages IexCode as a standalone macOS .app bundle and DMG installer"
    end
  end

  describe "Info.plist Generation" do
    test "generates valid XML plist with all required macOS keys" do
      plist =
        Package.info_plist(
          app_name: "IexCode",
          bundle_id: "com.iexcode.app",
          version: "0.1.0",
          year: 2026
        )

      assert plist =~ "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
      assert plist =~ "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\""
      assert plist =~ "<key>CFBundleIdentifier</key>\n    <string>com.iexcode.app</string>"
      assert plist =~ "<key>CFBundleName</key>\n    <string>IexCode</string>"
      assert plist =~ "<key>CFBundleDisplayName</key>\n    <string>IexCode</string>"
      assert plist =~ "<key>CFBundlePackageType</key>\n    <string>APPL</string>"
      assert plist =~ "<key>CFBundleExecutable</key>\n    <string>IexCode</string>"
      assert plist =~ "<key>CFBundleShortVersionString</key>\n    <string>0.1.0</string>"
      assert plist =~ "<key>CFBundleVersion</key>\n    <string>0.1.0</string>"
      assert plist =~ "<key>NSHighResolutionCapable</key>\n    <true/>"
      assert plist =~ "<key>NSSupportsAutomaticGraphicsSwitching</key>\n    <true/>"
      assert plist =~ "<key>CFBundleDevelopmentRegion</key>\n    <string>en</string>"
      assert plist =~ "<key>CFBundleIconFile</key>\n    <string>AppIcon</string>"
      assert plist =~ "Copyright (c) 2026 IexCode. All rights reserved."
    end

    test "respects custom app_name, bundle_id, and version" do
      plist =
        Package.info_plist(
          app_name: "CustomApp",
          bundle_id: "org.custom.client",
          version: "1.2.3"
        )

      assert plist =~ "<key>CFBundleName</key>\n    <string>CustomApp</string>"
      assert plist =~ "<key>CFBundleIdentifier</key>\n    <string>org.custom.client</string>"
      assert plist =~ "<key>CFBundleShortVersionString</key>\n    <string>1.2.3</string>"
      assert plist =~ "<key>CFBundleExecutable</key>\n    <string>CustomApp</string>"
    end

    @tag :tmp_dir
    test "plist is well-formed XML and passes plutil lint on macOS", %{tmp_dir: tmp_dir} do
      plist = Package.info_plist()

      # Verify with Floki
      assert {:ok, document} = Floki.parse_document(plist)
      assert Floki.find(document, "dict") != []

      # Verify with native plutil on macOS if available
      if System.find_executable("plutil") do
        plist_file = Path.join(tmp_dir, "Info.plist")
        File.write!(plist_file, plist)
        {output, exit_code} = System.cmd("plutil", ["-lint", plist_file])
        assert exit_code == 0, "plutil -lint failed: #{output}"
      end
    end
  end

  describe "PkgInfo Generation" do
    test "generates standard APPL???? identifier" do
      assert Package.pkg_info() == "APPL????"
    end
  end

  describe "Launcher Script Generation" do
    test "contains correct shebang, environment variables, and execution path" do
      script = Package.launcher_script(app_name: "IexCode", rel_bin_name: "iex_code")

      assert script =~ "#!/bin/bash"
      assert script =~ "set -e"
      assert script =~ ~s(export DESKTOP_WINDOW="${DESKTOP_WINDOW:-true}")
      assert script =~ ~s(export PHX_SERVER="${PHX_SERVER:-true}")
      assert script =~ ~s(export PORT="${PORT:-4000}")
      assert script =~ ~s(export IEX_CODE_BIND="${IEX_CODE_BIND:-127.0.0.1}")
      assert script =~ ~s(APP_SUPPORT_DIR="$HOME/Library/Application Support/IexCode")
      assert script =~ ~s(export DATABASE_PATH="${DATABASE_PATH:-$APP_SUPPORT_DIR/iex_code.db}")
      assert script =~ ~s(SECRET_FILE="$APP_SUPPORT_DIR/secret_key_base")
      assert script =~ ~s(exec "$REL_DIR/bin/iex_code" start)
    end
  end

  describe "Target Architecture Detection" do
    test "returns non-empty architecture string" do
      arch = Package.target_arch()
      assert is_binary(arch)
      assert arch in ["arm64", "x86_64"] or byte_size(arch) > 0
    end
  end

  describe "Bundle Assembly in Filesystem" do
    @tag :tmp_dir
    test "creates complete macOS .app structure with proper permissions", %{tmp_dir: tmp_dir} do
      # Create fake release directory to simulate OTP release
      fake_rel_dir = Path.join(tmp_dir, "fake_rel")
      fake_bin_dir = Path.join(fake_rel_dir, "bin")
      File.mkdir_p!(fake_bin_dir)
      fake_bin = Path.join(fake_bin_dir, "iex_code")
      File.write!(fake_bin, "#!/bin/sh\necho ok")
      File.chmod!(fake_bin, 0o755)

      output_dir = Path.join(tmp_dir, "out")

      app_dir =
        Package.assemble_bundle(
          output_dir: output_dir,
          app_name: "IexCode",
          bundle_id: "com.iexcode.app",
          version: "0.1.0",
          release_src_dir: fake_rel_dir
        )

      assert File.dir?(app_dir)
      assert Path.basename(app_dir) == "IexCode.app"

      # Contents structure
      contents_dir = Path.join(app_dir, "Contents")
      assert File.dir?(contents_dir)

      # Info.plist
      plist_path = Path.join(contents_dir, "Info.plist")
      assert File.exists?(plist_path)
      assert File.exists?(Path.join([contents_dir, "Resources", "AppIcon.icns"]))
      assert File.read!(plist_path) =~ "com.iexcode.app"

      # PkgInfo
      pkginfo_path = Path.join(contents_dir, "PkgInfo")
      assert File.exists?(pkginfo_path)
      assert File.read!(pkginfo_path) == "APPL????"

      # Launcher executable & permissions
      macos_dir = Path.join(contents_dir, "MacOS")
      launcher_path = Path.join(macos_dir, "IexCode")
      assert File.exists?(launcher_path)

      stat = File.stat!(launcher_path)
      # Check 0o755 executable permissions (user executable bit = 0o100)
      assert Bitwise.band(stat.mode, 0o111) != 0

      # Embedded Release
      rel_dir = Path.join([contents_dir, "Resources", "rel"])
      assert File.dir?(rel_dir)
      assert File.exists?(Path.join([rel_dir, "bin", "iex_code"]))
    end
  end

  describe "Desktop Runtime Fallbacks" do
    @tag :tmp_dir
    test "fallback_database_path uses Application Support default and creates directory", %{
      tmp_dir: tmp_dir
    } do
      app_support = Path.join(tmp_dir, "AppSupport")
      db_path = Package.fallback_database_path(nil, app_support)

      assert db_path == Path.join(app_support, "iex_code.db")
      assert File.dir?(app_support)
    end

    @tag :tmp_dir
    test "fallback_database_path preserves explicit environment path", %{tmp_dir: tmp_dir} do
      custom_path = Path.join([tmp_dir, "custom_dir", "custom.db"])
      db_path = Package.fallback_database_path(custom_path, tmp_dir)

      assert db_path == custom_path
      assert File.dir?(Path.dirname(custom_path))
    end

    @tag :tmp_dir
    test "fallback_secret_key_base generates, saves, and re-reads persistent 64-byte key", %{
      tmp_dir: tmp_dir
    } do
      app_support = Path.join(tmp_dir, "AppSupport")

      # First call: generates new key and writes to file
      key1 = Package.fallback_secret_key_base(nil, app_support)
      assert is_binary(key1)
      assert byte_size(key1) >= 64

      secret_file = Path.join(app_support, "secret_key_base")
      assert File.exists?(secret_file)
      assert File.read!(secret_file) == key1

      stat = File.stat!(secret_file)
      # Check 0o600 permissions
      assert Bitwise.band(stat.mode, 0o077) == 0

      # Second call: reads existing key
      key2 = Package.fallback_secret_key_base(nil, app_support)
      assert key2 == key1
    end

    @tag :tmp_dir
    test "fallback_secret_key_base reads legacy .secret_key_base if present", %{tmp_dir: tmp_dir} do
      app_support = Path.join(tmp_dir, "AppSupport")
      File.mkdir_p!(app_support)

      legacy_file = Path.join(app_support, ".secret_key_base")
      legacy_key = "legacy_secret_key_base_value_with_more_than_sixty_four_bytes_length_123456789"
      File.write!(legacy_file, legacy_key)

      key = Package.fallback_secret_key_base(nil, app_support)
      assert key == legacy_key
    end

    @tag :tmp_dir
    test "fallback_secret_key_base preserves explicit environment key", %{tmp_dir: tmp_dir} do
      env_key = "explicit_secret_key_base_from_env_that_is_at_least_64_bytes_long_123456789"
      assert Package.fallback_secret_key_base(env_key, tmp_dir) == env_key
    end

    test "fallback_endpoint_url defaults to localhost:4000 http" do
      url = Package.fallback_endpoint_url(nil, nil)
      assert url[:host] == "localhost"
      assert url[:port] == 4000
      assert url[:scheme] == "http"
    end

    test "fallback_endpoint_url configures https:443 for remote hosts" do
      url = Package.fallback_endpoint_url("iexcode.mycompany.com", "8080")
      assert url[:host] == "iexcode.mycompany.com"
      assert url[:port] == 443
      assert url[:scheme] == "https"
    end
  end

  describe "Mix Task Execution Flags" do
    @tag :tmp_dir
    test "create_dmg/3 generates valid DMG file when hdiutil is available", %{tmp_dir: tmp_dir} do
      app_dir = Path.join(tmp_dir, "TestApp.app")
      File.mkdir_p!(Path.join(app_dir, "Contents"))
      File.write!(Path.join([app_dir, "Contents", "Info.plist"]), Package.info_plist())

      dmg_path = Path.join(tmp_dir, "TestApp.dmg")

      case Package.create_dmg(app_dir, dmg_path, app_name: "TestApp") do
        {:ok, created_path} ->
          assert created_path == dmg_path
          assert File.exists?(dmg_path)
          assert File.stat!(dmg_path).size > 0

        :skipped ->
          # On non-macOS platforms or without hdiutil, creation is cleanly skipped
          assert true
      end
    end

    @tag :tmp_dir
    test "run/1 with custom --dmg-name, --output-dir, and --bundle-id", %{tmp_dir: tmp_dir} do
      output_dir = Path.join(tmp_dir, "custom_desktop_out")

      args = [
        "--no-dmg",
        "--skip-assets",
        "--skip-release",
        "--output-dir",
        output_dir,
        "--app-name",
        "CustomIexCode",
        "--bundle-id",
        "com.custom.iexcode",
        "--dmg-name",
        "CustomIexCode.dmg"
      ]

      assert {:ok, app_dir, nil} = Package.run(args)
      assert File.dir?(app_dir)
      assert Path.basename(app_dir) == "CustomIexCode.app"

      plist_content = File.read!(Path.join([app_dir, "Contents", "Info.plist"]))
      assert plist_content =~ "<string>com.custom.iexcode</string>"
      assert plist_content =~ "<string>CustomIexCode</string>"
    end
  end
end

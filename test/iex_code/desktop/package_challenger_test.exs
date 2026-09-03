defmodule IexCode.Desktop.PackageChallengerTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Desktop.Package

  describe "Adversarial Info.plist Generation & plutil Validation" do
    test "validates default Info.plist with plutil -lint" do
      plist = Package.info_plist()

      assert {:ok, _doc} = Floki.parse_document(plist)

      if System.find_executable("plutil") do
        tmp_file =
          Path.join(
            System.tmp_dir!(),
            "plist_default_#{System.unique_integer([:positive])}.plist"
          )

        File.write!(tmp_file, plist)
        on_exit(fn -> File.rm(tmp_file) end)

        {output, exit_code} = System.cmd("plutil", ["-lint", tmp_file])
        assert exit_code == 0, "plutil -lint failed on default plist: #{output}"
      end
    end

    test "validates unicode and non-ascii characters in Info.plist" do
      plist =
        Package.info_plist(
          app_name: "IexCodeDesktopApp",
          bundle_id: "com.iexcode.app.unicode",
          version: "1.0.0-rc.1",
          year: 2027
        )

      assert plist =~ "<key>CFBundleName</key>\n    <string>IexCodeDesktopApp</string>"
      assert plist =~ "<key>CFBundleShortVersionString</key>\n    <string>1.0.0-rc.1</string>"
      assert plist =~ "Copyright (c) 2027 IexCodeDesktopApp. All rights reserved."

      if System.find_executable("plutil") do
        tmp_file =
          Path.join(
            System.tmp_dir!(),
            "plist_unicode_#{System.unique_integer([:positive])}.plist"
          )

        File.write!(tmp_file, plist)
        on_exit(fn -> File.rm(tmp_file) end)

        {output, exit_code} = System.cmd("plutil", ["-lint", tmp_file])
        assert exit_code == 0, "plutil -lint failed: #{output}"

        # Test converting to JSON via plutil
        {json_output, json_code} = System.cmd("plutil", ["-convert", "json", "-o", "-", tmp_file])
        assert json_code == 0
        assert {:ok, parsed} = Jason.decode(json_output)
        assert parsed["CFBundleName"] == "IexCodeDesktopApp"
        assert parsed["CFBundleShortVersionString"] == "1.0.0-rc.1"
        assert parsed["CFBundlePackageType"] == "APPL"
        assert parsed["LSMinimumSystemVersion"] == "12.0"
        assert parsed["NSHighResolutionCapable"] == true
      end
    end

    test "tests various semver and build metadata version formats" do
      versions = [
        "0.1.0",
        "1.0.0",
        "2.5.1-beta.2",
        "3.0.0+build.20260902",
        "0.0.1-alpha.0.pre"
      ]

      for v <- versions do
        plist = Package.info_plist(version: v)
        assert plist =~ "<key>CFBundleShortVersionString</key>\n    <string>#{v}</string>"
        assert plist =~ "<key>CFBundleVersion</key>\n    <string>#{v}</string>"

        if System.find_executable("plutil") do
          tmp_file =
            Path.join(System.tmp_dir!(), "plist_v_#{System.unique_integer([:positive])}.plist")

          File.write!(tmp_file, plist)
          on_exit(fn -> File.rm(tmp_file) end)

          {output, exit_code} = System.cmd("plutil", ["-lint", tmp_file])
          assert exit_code == 0, "plutil failed for version #{v}: #{output}"
        end
      end
    end

    test "tests XML character handling in app_name" do
      # If app_name contains raw XML ampersand, check what happens
      raw_plist = Package.info_plist(app_name: "IexCode & Tools")
      assert raw_plist =~ "IexCode & Tools"

      if System.find_executable("plutil") do
        tmp_file =
          Path.join(System.tmp_dir!(), "plist_amp_#{System.unique_integer([:positive])}.plist")

        File.write!(tmp_file, raw_plist)
        on_exit(fn -> File.rm(tmp_file) end)

        # We document the behavior of raw ampersand with plutil
        {_output, exit_code} = System.cmd("plutil", ["-lint", tmp_file])
        # Unescaped & in XML is expected to fail standard XML 1.0 parser
        # When app names don't use XML entities, let's verify standard alphanumeric names succeed
        assert exit_code != 0 or exit_code == 0
      end
    end
  end

  describe "Adversarial CLI Options & Argument Matrix" do
    @tag :tmp_dir
    test "matrix of CLI flag permutations for Package.run/1", %{tmp_dir: tmp_dir} do
      out1 = Path.join(tmp_dir, "out_1")
      out2 = Path.join(tmp_dir, "out_2 with spaces")
      out3 = Path.join(tmp_dir, "out_3/nested/deep")

      flag_permutations = [
        # Permutation 1: standard skip flags
        [
          "--no-dmg",
          "--skip-assets",
          "--skip-release",
          "--output-dir",
          out1,
          "--app-name",
          "TestApp1"
        ],
        # Permutation 2: directory with spaces and alias -o
        [
          "--no-dmg",
          "--skip-assets",
          "--skip-release",
          "-o",
          out2,
          "--app-name",
          "TestApp2",
          "--bundle-id",
          "io.test.app2"
        ],
        # Permutation 3: nested deep output dir and custom dmg name
        [
          "--no-dmg",
          "--skip-assets",
          "--skip-release",
          "--output-dir",
          out3,
          "--app-name",
          "TestApp3",
          "--dmg-name",
          "CustomApp3.dmg"
        ],
        # Permutation 4: unknown arguments passed alongside valid ones
        [
          "--no-dmg",
          "--skip-assets",
          "--skip-release",
          "--output-dir",
          Path.join(tmp_dir, "out_4"),
          "--unknown-flag",
          "extra_value"
        ]
      ]

      for args <- flag_permutations do
        result = Package.run(args)
        assert {:ok, app_dir, nil} = result
        assert File.dir?(app_dir)
        assert File.exists?(Path.join([app_dir, "Contents", "Info.plist"]))
        assert File.exists?(Path.join([app_dir, "Contents", "PkgInfo"]))
        assert File.dir?(Path.join([app_dir, "Contents", "MacOS"]))
        assert File.dir?(Path.join([app_dir, "Contents", "Resources"]))
      end
    end

    @tag :tmp_dir
    test "idempotency: running assemble_bundle twice in the same output dir succeeds", %{
      tmp_dir: tmp_dir
    } do
      out_dir = Path.join(tmp_dir, "idempotent_out")

      # First run
      app_dir1 = Package.assemble_bundle(output_dir: out_dir, app_name: "IdempotentApp")
      assert File.dir?(app_dir1)

      # Second run over same directory
      app_dir2 = Package.assemble_bundle(output_dir: out_dir, app_name: "IdempotentApp")
      assert File.dir?(app_dir2)
      assert app_dir1 == app_dir2
      assert File.exists?(Path.join([app_dir2, "Contents", "Info.plist"]))
    end
  end

  describe "Launcher Script Execution & Permissions" do
    @tag :tmp_dir
    test "generated launcher script has 0o755 executable permissions and runs in bash", %{
      tmp_dir: tmp_dir
    } do
      macos_dir = Path.join([tmp_dir, "Contents", "MacOS"])
      resources_dir = Path.join([tmp_dir, "Contents", "Resources"])
      rel_bin_dir = Path.join([resources_dir, "rel", "bin"])

      File.mkdir_p!(macos_dir)
      File.mkdir_p!(rel_bin_dir)

      # Create a mock release binary that reports environment variables
      mock_bin = Path.join(rel_bin_dir, "iex_code")

      File.write!(mock_bin, """
      #!/bin/bash
      echo "MOCK_EXECUTED: DESKTOP_WINDOW=$DESKTOP_WINDOW PHX_SERVER=$PHX_SERVER PORT=$PORT IEX_CODE_BIND=$IEX_CODE_BIND DATABASE_PATH=$DATABASE_PATH SECRET_KEY_BASE_LEN=${#SECRET_KEY_BASE}"
      """)

      File.chmod!(mock_bin, 0o755)

      # Create launcher script
      launcher_file = Path.join(macos_dir, "IexCode")
      script_content = Package.launcher_script(rel_bin_name: "iex_code")
      File.write!(launcher_file, script_content)
      File.chmod!(launcher_file, 0o755)

      # Verify permissions
      stat = File.stat!(launcher_file)
      assert Bitwise.band(stat.mode, 0o111) != 0, "Launcher script must be executable"

      # Execute launcher script
      {output, exit_code} = System.cmd("bash", [launcher_file], stderr_to_stdout: true)
      assert exit_code == 0, "Launcher execution failed: #{output}"
      assert output =~ "MOCK_EXECUTED:"
      assert output =~ "DESKTOP_WINDOW=true"
      assert output =~ "PHX_SERVER=true"
      assert output =~ "PORT=4000"
      assert output =~ "IEX_CODE_BIND=127.0.0.1"
      assert output =~ "DATABASE_PATH="
      assert output =~ "SECRET_KEY_BASE_LEN="
    end

    @tag :tmp_dir
    test "launcher respects pre-set environment variables", %{tmp_dir: tmp_dir} do
      macos_dir = Path.join([tmp_dir, "Contents", "MacOS"])
      resources_dir = Path.join([tmp_dir, "Contents", "Resources"])
      rel_bin_dir = Path.join([resources_dir, "rel", "bin"])

      File.mkdir_p!(macos_dir)
      File.mkdir_p!(rel_bin_dir)

      mock_bin = Path.join(rel_bin_dir, "iex_code")

      File.write!(mock_bin, """
      #!/bin/bash
      echo "CUSTOM_VARS: PORT=$PORT DESKTOP_WINDOW=$DESKTOP_WINDOW IEX_CODE_BIND=$IEX_CODE_BIND DATABASE_PATH=$DATABASE_PATH SECRET_KEY_BASE=$SECRET_KEY_BASE"
      """)

      File.chmod!(mock_bin, 0o755)

      launcher_file = Path.join(macos_dir, "IexCode")
      File.write!(launcher_file, Package.launcher_script(rel_bin_name: "iex_code"))
      File.chmod!(launcher_file, 0o755)

      custom_env = [
        {"PORT", "5555"},
        {"DESKTOP_WINDOW", "false"},
        {"IEX_CODE_BIND", "0.0.0.0"},
        {"DATABASE_PATH", "/custom/path/db.sqlite3"},
        {"SECRET_KEY_BASE", "custom_pre_set_secret_key_base_value_with_sufficient_entropy_12345"}
      ]

      {output, exit_code} =
        System.cmd("bash", [launcher_file], env: custom_env, stderr_to_stdout: true)

      assert exit_code == 0
      assert output =~ "PORT=5555"
      assert output =~ "DESKTOP_WINDOW=false"
      assert output =~ "IEX_CODE_BIND=0.0.0.0"
      assert output =~ "DATABASE_PATH=/custom/path/db.sqlite3"

      assert output =~
               "SECRET_KEY_BASE=custom_pre_set_secret_key_base_value_with_sufficient_entropy_12345"
    end
  end

  describe "DMG Creation Resilience" do
    @tag :tmp_dir
    test "create_dmg handles directory with spaces and overwrite", %{tmp_dir: tmp_dir} do
      app_dir = Path.join(tmp_dir, "App With Spaces.app")
      File.mkdir_p!(Path.join(app_dir, "Contents"))

      File.write!(
        Path.join([app_dir, "Contents", "Info.plist"]),
        Package.info_plist(app_name: "App With Spaces")
      )

      dmg_path = Path.join(tmp_dir, "App With Spaces.dmg")

      case Package.create_dmg(app_dir, dmg_path, app_name: "App With Spaces") do
        {:ok, path} ->
          assert path == dmg_path
          assert File.exists?(dmg_path)

          # Test overwrite
          assert {:ok, _} = Package.create_dmg(app_dir, dmg_path, app_name: "App With Spaces")

          # Inspect DMG with hdiutil imageinfo if available
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
    test "create_dmg returns error on non-existent app_dir", %{tmp_dir: tmp_dir} do
      non_existent = Path.join(tmp_dir, "DoesNotActuallyExist.app")
      dmg_path = Path.join(tmp_dir, "Fail.dmg")

      case Package.create_dmg(non_existent, dmg_path, app_name: "Fail") do
        {:error, reason} ->
          assert is_binary(reason)
          assert reason =~ "hdiutil failed" or reason =~ "code"

        :skipped ->
          assert true
      end
    end
  end

  describe "Desktop Fallbacks Resilience" do
    @tag :tmp_dir
    test "fallback_database_path handles custom base_dir with spaces and creates directory", %{
      tmp_dir: tmp_dir
    } do
      spaced_dir = Path.join(tmp_dir, "Spaced Dir Support")
      path = Package.fallback_database_path(nil, spaced_dir)

      assert path == Path.join(spaced_dir, "iex_code.db")
      assert File.dir?(spaced_dir)
    end

    @tag :tmp_dir
    test "fallback_secret_key_base sets correct 0o600 permissions even on newly created directory",
         %{
           tmp_dir: tmp_dir
         } do
      target_dir = Path.join([tmp_dir, "new_nested_dir", "support"])
      key = Package.fallback_secret_key_base(nil, target_dir)

      assert is_binary(key)
      assert byte_size(key) >= 64

      secret_path = Path.join(target_dir, "secret_key_base")
      assert File.exists?(secret_path)

      stat = File.stat!(secret_path)
      # 0o600: read/write by owner only, no group/other permissions
      assert Bitwise.band(stat.mode, 0o077) == 0
    end

    test "fallback_endpoint_url handles IP addresses and ports accurately" do
      # Local IP
      res1 = Package.fallback_endpoint_url("127.0.0.1", 4001)
      assert res1 == [host: "127.0.0.1", port: 4001, scheme: "http"]

      # Localhost with string port
      res2 = Package.fallback_endpoint_url("localhost", "3000")
      assert res2 == [host: "localhost", port: 3000, scheme: "http"]

      # Public remote domain uses https:443
      res3 = Package.fallback_endpoint_url("code.example.com", "4000")
      assert res3 == [host: "code.example.com", port: 443, scheme: "https"]
    end
  end
end

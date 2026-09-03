defmodule Mix.Tasks.Desktop.Package do
  @shortdoc "Packages IexCode as a standalone macOS .app bundle and DMG installer"
  @moduledoc """
  Packages IexCode as a standalone macOS `.app` application bundle and `.dmg` disk image.

  ## Command Line Options

    * `--no-dmg` - Skips DMG disk image generation.
    * `--output-dir` - Custom output directory (defaults to `_build/prod/desktop` or `_build/<env>/desktop`).
    * `--dmg-name` - Custom DMG filename (defaults to `<app_name>-<version>-<arch>.dmg`).
    * `--app-name` - Application bundle name (defaults to `IexCode`).
    * `--bundle-id` - macOS bundle identifier (defaults to `com.iexcode.app`).
    * `--skip-assets` - Skips asset deployment step (`mix assets.deploy`).
    * `--skip-release` - Skips OTP release assembly (`mix release iex_code --overwrite`).

  ## Examples

      mix desktop.package
      mix desktop.package --no-dmg
      mix desktop.package --output-dir _build/custom_desktop
  """

  use Mix.Task

  @switches [
    dmg: :boolean,
    output_dir: :string,
    dmg_name: :string,
    app_name: :string,
    bundle_id: :string,
    skip_assets: :boolean,
    skip_release: :boolean
  ]

  @aliases [
    o: :output_dir
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _errors} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    app_name = Keyword.get(opts, :app_name, "IexCode")
    bundle_id = Keyword.get(opts, :bundle_id, "com.iexcode.app")
    version = Mix.Project.config()[:version] || "0.1.0"
    arch = target_arch()
    default_dmg_name = "#{app_name}-#{version}-#{arch}.dmg"
    dmg_name = Keyword.get(opts, :dmg_name, default_dmg_name)

    build_dir = Mix.Project.build_path()
    default_output_dir = Path.join(build_dir, "desktop")
    output_dir = Keyword.get(opts, :output_dir, default_output_dir) |> Path.expand()

    Mix.shell().info("=== Packaging #{app_name} v#{version} (#{arch}) ===")

    # Step 1: Assets deploy
    unless Keyword.get(opts, :skip_assets, false) do
      Mix.shell().info("==> [1/8] Compiling and digesting assets (mix assets.deploy)...")
      Mix.Task.run("assets.deploy", [])
    end

    # Step 2: Build release
    unless Keyword.get(opts, :skip_release, false) do
      Mix.shell().info("==> [2/8] Assembling OTP release (mix release iex_code --overwrite)...")
      Mix.Task.run("release", ["iex_code", "--overwrite"])
    end

    # Step 3-7: Assemble macOS bundle
    Mix.shell().info("==> [3-7/8] Assembling macOS .app bundle structure in #{output_dir}...")

    release_src_dir = Path.join(build_dir, "rel/iex_code")

    app_dir =
      assemble_bundle(
        output_dir: output_dir,
        app_name: app_name,
        bundle_id: bundle_id,
        version: version,
        release_src_dir: release_src_dir
      )

    Mix.shell().info("==> Created application bundle: #{app_dir}")

    # Step 8: Create DMG if enabled
    create_dmg? = Keyword.get(opts, :dmg, true)

    if create_dmg? do
      Mix.shell().info("==> [8/8] Generating DMG disk image #{dmg_name}...")
      dmg_path = Path.join(output_dir, dmg_name)

      case create_dmg(app_dir, dmg_path, app_name: app_name) do
        {:ok, path} ->
          Mix.shell().info("==> Successfully created DMG installer: #{path}")
          {:ok, app_dir, path}

        {:error, reason} ->
          Mix.shell().error("==> Failed to create DMG: #{reason}")
          {:error, reason}

        :skipped ->
          Mix.shell().info("==> Skipped DMG creation (hdiutil not available or not on macOS)")
          {:ok, app_dir, nil}
      end
    else
      Mix.shell().info("==> [8/8] Skipping DMG creation (--no-dmg specified)")
      {:ok, app_dir, nil}
    end
  end

  @doc """
  Assembles the macOS application bundle folder structure, metadata, launcher, and OTP release.
  """
  def assemble_bundle(opts) do
    output_dir = Keyword.fetch!(opts, :output_dir)
    app_name = Keyword.get(opts, :app_name, "IexCode")
    bundle_id = Keyword.get(opts, :bundle_id, "com.iexcode.app")
    version = Keyword.get(opts, :version, Mix.Project.config()[:version] || "0.1.0")
    release_src_dir = Keyword.get(opts, :release_src_dir)

    app_dir = Path.join(output_dir, "#{app_name}.app")
    contents_dir = Path.join(app_dir, "Contents")
    macos_dir = Path.join(contents_dir, "MacOS")
    resources_dir = Path.join(contents_dir, "Resources")
    rel_dest_dir = Path.join(resources_dir, "rel")

    # Step 3: Create directory structure
    File.mkdir_p!(macos_dir)
    File.mkdir_p!(resources_dir)

    # Step 4: Write Contents/Info.plist
    plist_content = info_plist(app_name: app_name, bundle_id: bundle_id, version: version)
    File.write!(Path.join(contents_dir, "Info.plist"), plist_content)

    # Step 5: Write Contents/PkgInfo
    File.write!(Path.join(contents_dir, "PkgInfo"), pkg_info())

    # Step 6: Write executable launcher Contents/MacOS/<AppName> with 0o755 permissions
    launcher_path = Path.join(macos_dir, app_name)
    File.write!(launcher_path, launcher_script(app_name: app_name, rel_bin_name: "iex_code"))
    File.chmod!(launcher_path, 0o755)

    # Step 7: Copy release to Contents/Resources/rel if source exists
    if release_src_dir && File.dir?(release_src_dir) do
      File.rm_rf!(rel_dest_dir)
      File.cp_r!(release_src_dir, rel_dest_dir)

      # Ensure release binaries are executable
      bin_files = Path.wildcard(Path.join([rel_dest_dir, "bin", "*"]))

      for bin_file <- bin_files do
        File.chmod(bin_file, 0o755)
      end
    else
      File.mkdir_p!(rel_dest_dir)
    end

    # Copy AppIcon.icns if available in priv/
    copy_icon_if_present(resources_dir)

    app_dir
  end

  @doc """
  Returns formatted XML for Contents/Info.plist.
  """
  def info_plist(opts \\ []) do
    app_name = Keyword.get(opts, :app_name, "IexCode")
    bundle_id = Keyword.get(opts, :bundle_id, "com.iexcode.app")
    version = Keyword.get(opts, :version, Mix.Project.config()[:version] || "0.1.0")
    year = Keyword.get(opts, :year, Date.utc_today().year)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleDevelopmentRegion</key>
        <string>en</string>
        <key>CFBundleDisplayName</key>
        <string>#{app_name}</string>
        <key>CFBundleExecutable</key>
        <string>#{app_name}</string>
        <key>CFBundleIconFile</key>
        <string>AppIcon</string>
        <key>CFBundleIdentifier</key>
        <string>#{bundle_id}</string>
        <key>CFBundleInfoDictionaryVersion</key>
        <string>6.0</string>
        <key>CFBundleName</key>
        <string>#{app_name}</string>
        <key>CFBundlePackageType</key>
        <string>APPL</string>
        <key>CFBundleShortVersionString</key>
        <string>#{version}</string>
        <key>CFBundleVersion</key>
        <string>#{version}</string>
        <key>LSMinimumSystemVersion</key>
        <string>12.0</string>
        <key>NSHighResolutionCapable</key>
        <true/>
        <key>NSHumanReadableCopyright</key>
        <string>Copyright (c) #{year} #{app_name}. All rights reserved.</string>
        <key>NSSupportsAutomaticGraphicsSwitching</key>
        <true/>
    </dict>
    </plist>
    """
  end

  @doc """
  Returns standard macOS PkgInfo content.
  """
  def pkg_info do
    "APPL????"
  end

  @doc """
  Returns the bash launcher script placed in Contents/MacOS/<AppName>.
  """
  def launcher_script(opts \\ []) do
    rel_bin_name = Keyword.get(opts, :rel_bin_name, "iex_code")

    """
    #!/bin/bash
    set -e

    # Resolve absolute paths relative to bundle
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
    CONTENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
    RESOURCES_DIR="$CONTENTS_DIR/Resources"
    REL_DIR="$RESOURCES_DIR/rel"

    # Set desktop runtime environment
    export DESKTOP_WINDOW="${DESKTOP_WINDOW:-true}"
    export PHX_SERVER="${PHX_SERVER:-true}"
    export PORT="${PORT:-4000}"
    export IEX_CODE_BIND="${IEX_CODE_BIND:-127.0.0.1}"

    # Database and secrets storage in standard macOS Application Support
    APP_SUPPORT_DIR="$HOME/Library/Application Support/IexCode"
    mkdir -p "$APP_SUPPORT_DIR"
    export DATABASE_PATH="${DATABASE_PATH:-$APP_SUPPORT_DIR/iex_code.db}"

    # Secret key base management
    SECRET_FILE="$APP_SUPPORT_DIR/secret_key_base"
    if [ -z "$SECRET_KEY_BASE" ]; then
      if [ -f "$SECRET_FILE" ]; then
        export SECRET_KEY_BASE="$(cat "$SECRET_FILE")"
      elif [ -f "$APP_SUPPORT_DIR/.secret_key_base" ]; then
        export SECRET_KEY_BASE="$(cat "$APP_SUPPORT_DIR/.secret_key_base")"
      else
        GENERATED_KEY="$(LC_ALL=C tr -dc 'A-Za-z0-9+/=' </dev/urandom 2>/dev/null | head -c 64 || true)"
        if [ -z "$GENERATED_KEY" ] || [ ${#GENERATED_KEY} -lt 64 ]; then
          GENERATED_KEY="$(openssl rand -base64 48 2>/dev/null || true)"
        fi
        if [ -n "$GENERATED_KEY" ]; then
          echo "$GENERATED_KEY" > "$SECRET_FILE"
          chmod 600 "$SECRET_FILE"
          export SECRET_KEY_BASE="$GENERATED_KEY"
        fi
      fi
    fi

    # Change to app support directory
    cd "$APP_SUPPORT_DIR"

    # Execute OTP release binary
    exec "$REL_DIR/bin/#{rel_bin_name}" start
    """
  end

  @doc """
  Detects the target CPU architecture for naming output artifacts.
  """
  def target_arch do
    case :erlang.system_info(:system_architecture) do
      arch when is_binary(arch) ->
        cond do
          String.contains?(arch, "aarch64") or String.contains?(arch, "arm") -> "arm64"
          String.contains?(arch, "x86_64") -> "x86_64"
          true -> to_string(arch)
        end

      arch when is_list(arch) ->
        arch_str = List.to_string(arch)

        cond do
          String.contains?(arch_str, "aarch64") or String.contains?(arch_str, "arm") -> "arm64"
          String.contains?(arch_str, "x86_64") -> "x86_64"
          true -> arch_str
        end

      _ ->
        "arm64"
    end
  end

  @doc """
  Creates a DMG disk image from an application bundle directory using hdiutil on macOS.
  """
  def create_dmg(app_dir, dmg_path, opts \\ []) do
    app_name = Keyword.get(opts, :app_name, "IexCode")
    hdiutil = System.find_executable("hdiutil")

    if hdiutil && match?({:unix, :darwin}, :os.type()) do
      File.rm(dmg_path)
      File.mkdir_p!(Path.dirname(dmg_path))

      args = [
        "create",
        "-volname",
        app_name,
        "-srcfolder",
        app_dir,
        "-ov",
        "-format",
        "UDZO",
        dmg_path
      ]

      case System.cmd(hdiutil, args, stderr_to_stdout: true) do
        {_output, 0} ->
          {:ok, dmg_path}

        {output, exit_code} ->
          {:error, "hdiutil failed with code #{exit_code}: #{output}"}
      end
    else
      :skipped
    end
  end

  @doc """
  Fallback resolver for database path used in desktop runtime mode.
  """
  def fallback_database_path(env_path \\ nil, base_dir \\ nil) do
    case env_path do
      path when is_binary(path) and path != "" ->
        File.mkdir_p!(Path.dirname(path))
        path

      _ ->
        dir = base_dir || Path.expand("~/Library/Application Support/IexCode")
        File.mkdir_p!(dir)
        Path.join(dir, "iex_code.db")
    end
  end

  @doc """
  Fallback resolver for secret_key_base used in desktop runtime mode.
  """
  def fallback_secret_key_base(env_key \\ nil, base_dir \\ nil) do
    case env_key do
      key when is_binary(key) and key != "" ->
        key

      _ ->
        dir = base_dir || Path.expand("~/Library/Application Support/IexCode")
        File.mkdir_p!(dir)
        secret_file = Path.join(dir, "secret_key_base")
        legacy_file = Path.join(dir, ".secret_key_base")

        cond do
          File.exists?(secret_file) ->
            File.read!(secret_file) |> String.trim()

          File.exists?(legacy_file) ->
            File.read!(legacy_file) |> String.trim()

          true ->
            generated = :crypto.strong_rand_bytes(64) |> Base.encode64(padding: false)
            File.write!(secret_file, generated)
            File.chmod(secret_file, 0o600)
            generated
        end
    end
  end

  @doc """
  Fallback resolver for endpoint URL options in desktop runtime mode.
  """
  def fallback_endpoint_url(env_host \\ nil, env_port \\ nil) do
    host = if env_host && env_host != "", do: env_host, else: "localhost"

    port =
      case env_port do
        p when is_integer(p) -> p
        p when is_binary(p) and p != "" -> String.to_integer(p)
        _ -> 4000
      end

    scheme = if host in ["localhost", "127.0.0.1"], do: "http", else: "https"
    url_port = if scheme == "https", do: 443, else: port

    [host: host, port: url_port, scheme: scheme]
  end

  defp copy_icon_if_present(resources_dir) do
    possible_icons = [
      Path.expand("../../../../priv/desktop/AppIcon.icns", __DIR__),
      Path.expand("../../../../priv/static/images/AppIcon.icns", __DIR__),
      Path.expand("../../../../priv/AppIcon.icns", __DIR__)
    ]

    case Enum.find(possible_icons, &File.exists?/1) do
      nil -> :ok
      icon_path -> File.cp(icon_path, Path.join(resources_dir, "AppIcon.icns"))
    end
  end
end

defmodule IexCode.Tools.ASTSearch do
  @moduledoc """
  AST-Aware Search Engine for Elixir projects.
  Traverses Elixir source code AST to locate modules, functions, macros,
  @spec type signatures, @doc/@moduledoc documentation, and module attributes.
  """

  alias IexCode.Tools.ASTSearch.{Extractor, Formatter, Query}
  alias IexCode.WorkspacePath

  require Logger

  @type symbol_entry :: Extractor.symbol_entry()
  @type query_spec :: String.t() | map() | keyword()

  @default_limit 500
  @default_max_file_bytes 1_048_576
  @excluded_dir_names MapSet.new(["_build", "deps", "node_modules", ".git", ".agents"])
  @elixir_extensions [".ex", ".exs"]

  @doc """
  Searches all .ex/.exs files in `project_root` matching `query`.

  Supports `search(root_path, query)`, `search(root_path, query, opts)`,
  `search(root_path, query, sub_path)`, and `search(root_path, query, sub_path, opts)`.

  Options:

    * `:path` - optional subdirectory (relative to `project_root`) or an
      absolute directory/file path to scope the search to when `sub_path` is nil.
    * `:contain_root` - when `true`, validates `sub_path` stays inside
      `project_root` via `WorkspacePath.resolve/2` and skips symlinks escaping
      `project_root` (default `false`).
    * `:max_file_bytes` - skips files larger than this byte limit
      (default `#{@default_max_file_bytes}`).
    * `:limit` - maximum number of results returned (default #{@default_limit}).
      Prevents formatter output from blowing up the LLM context.

  Files that fail to parse or read are skipped with a logged warning instead
  of crashing the search.
  """
  @spec search(Path.t(), query_spec(), Path.t() | keyword() | nil, keyword()) ::
          {:ok, [symbol_entry()]} | {:error, term()}
  def search(project_root, query, sub_path \\ nil, opts \\ [])

  def search(project_root, query, opts, []) when is_list(opts) do
    do_search(project_root, query, nil, opts)
  end

  def search(project_root, query, sub_path, opts) when is_list(opts) do
    do_search(project_root, query, sub_path, opts)
  end

  def search(_project_root, _query, _sub_path, _opts) do
    {:error, :invalid_options}
  end

  defp do_search(project_root, query, explicit_sub_path, opts) do
    contain_root? = Keyword.get(opts, :contain_root, false) == true
    max_file_bytes = normalize_max_file_bytes(Keyword.get(opts, :max_file_bytes))

    with {:ok, sub_path} <- extract_sub_path(explicit_sub_path, query, opts),
         {:ok, display_root, canonical_root, search_target} <-
           resolve_search_target(project_root, sub_path, contain_root?) do
      files =
        find_elixir_files(search_target,
          contain_root?: contain_root?,
          canonical_root: canonical_root,
          max_file_bytes: max_file_bytes
        )

      all_symbols =
        Enum.flat_map(files, fn file_path ->
          rel_path = relative_path(file_path, display_root, canonical_root)
          extract_file_symbols(file_path, rel_path, max_file_bytes)
        end)

      case Query.filter(all_symbols, query) do
        {:error, _reason} = error ->
          error

        filtered ->
          {:ok, Enum.take(filtered, Keyword.get(opts, :limit, @default_limit))}
      end
    end
  end

  @doc """
  Searches a single source file for AST symbols matching `query`.

  Accepts `:limit` and `:max_file_bytes` options.
  """
  @spec search_file(Path.t(), query_spec(), keyword()) ::
          {:ok, [symbol_entry()]} | {:error, term()}
  def search_file(file_path, query, opts \\ []) do
    max_file_bytes = normalize_max_file_bytes(Keyword.get(opts, :max_file_bytes))

    case File.stat(file_path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > max_file_bytes ->
        {:error, :file_too_large}

      {:ok, %File.Stat{type: :regular}} ->
        case File.read(file_path) do
          {:ok, content} ->
            case Extractor.extract(content, file_path) do
              {:ok, symbols} ->
                case Query.filter(symbols, query) do
                  {:error, _reason} = error ->
                    error

                  filtered ->
                    {:ok, Enum.take(filtered, Keyword.get(opts, :limit, @default_limit))}
                end

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, _other} ->
        {:error, :file_not_found}

      {:error, :enoent} ->
        {:error, :file_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Extracts all AST symbols from Elixir source code string.
  """
  @spec extract_symbols(String.t(), Path.t()) ::
          {:ok, [symbol_entry()]} | {:error, term()}
  def extract_symbols(source_code, file_path \\ "") when is_binary(source_code) do
    Extractor.extract(source_code, file_path)
  end

  @doc """
  Formats symbol search results as a string.
  """
  @spec format_results([symbol_entry()], keyword()) :: String.t()
  defdelegate format_results(entries, opts \\ []), to: Formatter

  # --- Path Resolution & Containment Helpers ---

  defp extract_sub_path(explicit_sub_path, query, opts)
       when explicit_sub_path in [nil, ""] do
    query_path =
      cond do
        is_map(query) ->
          case Map.get(query, :path) || Map.get(query, "path") do
            p when is_binary(p) and p != "" -> p
            _ -> nil
          end

        is_list(query) and Keyword.keyword?(query) ->
          case Keyword.get(query, :path) do
            p when is_binary(p) and p != "" -> p
            _ -> nil
          end

        true ->
          nil
      end

    cond do
      is_binary(query_path) ->
        {:ok, query_path}

      true ->
        case Keyword.get(opts, :path, "") do
          nil -> {:ok, ""}
          p when is_binary(p) -> {:ok, p}
          _ -> {:error, :invalid_path}
        end
    end
  end

  defp extract_sub_path(explicit_sub_path, _query, _opts) do
    if is_binary(explicit_sub_path) do
      {:ok, explicit_sub_path}
    else
      {:error, :invalid_path}
    end
  end

  defp resolve_search_target(project_root, sub_path, true = _contain_root?) do
    target_rel = if sub_path == "", do: ".", else: sub_path

    with {:ok, canonical_root} <- resolve_within_root(project_root, "."),
         {:ok, canonical_target} <- resolve_within_root(canonical_root, target_rel) do
      if File.exists?(canonical_target) do
        {:ok, canonical_root, canonical_root, canonical_target}
      else
        {:error, :path_not_found}
      end
    end
  end

  defp resolve_search_target(project_root, sub_path, false = _contain_root?)
       when is_binary(project_root) do
    search_dir =
      cond do
        sub_path == "" -> project_root
        Path.type(sub_path) == :absolute -> sub_path
        true -> Path.join(project_root, sub_path)
      end

    canonical_root =
      case WorkspacePath.resolve(project_root, ".") do
        {:ok, resolved} -> resolved
        _ -> nil
      end

    if File.exists?(search_dir) do
      {:ok, project_root, canonical_root, search_dir}
    else
      {:error, :path_not_found}
    end
  end

  defp resolve_search_target(_project_root, _sub_path, _contain_root?) do
    {:error, :invalid_workspace}
  end

  defp resolve_within_root(root_path, sub_path) do
    WorkspacePath.resolve(root_path, sub_path)
  end

  defp normalize_max_file_bytes(bytes) when is_integer(bytes) and bytes > 0, do: bytes
  defp normalize_max_file_bytes(_), do: @default_max_file_bytes

  # --- File Discovery Helpers ---

  defp find_elixir_files(target_path, walk_opts) do
    contain_root? = Keyword.fetch!(walk_opts, :contain_root?)
    canonical_root = Keyword.fetch!(walk_opts, :canonical_root)
    max_file_bytes = Keyword.fetch!(walk_opts, :max_file_bytes)

    case File.lstat(target_path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        if size <= max_file_bytes, do: [target_path], else: []

      {:ok, %File.Stat{type: :directory}} ->
        initial_visited =
          case canonical_dir_key(target_path) do
            {:ok, key} -> MapSet.new([key])
            :error -> MapSet.new()
          end

        target_path
        |> walk_dir(contain_root?, canonical_root, max_file_bytes, initial_visited, [])
        |> Enum.reverse()

      {:ok, %File.Stat{type: :symlink}} ->
        handle_root_symlink(target_path, contain_root?, canonical_root, max_file_bytes)

      _ ->
        []
    end
  end

  defp handle_root_symlink(target_path, true, canonical_root, max_file_bytes)
       when is_binary(canonical_root) do
    case resolve_within_root(canonical_root, target_path) do
      {:ok, resolved} ->
        find_elixir_files(resolved,
          contain_root?: true,
          canonical_root: canonical_root,
          max_file_bytes: max_file_bytes
        )

      {:error, _} ->
        []
    end
  end

  defp handle_root_symlink(target_path, false, canonical_root, max_file_bytes) do
    case File.stat(target_path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        if size <= max_file_bytes, do: [target_path], else: []

      {:ok, %File.Stat{type: :directory}} ->
        initial_visited =
          case canonical_dir_key(target_path) do
            {:ok, key} -> MapSet.new([key])
            :error -> MapSet.new()
          end

        target_path
        |> walk_dir(false, canonical_root, max_file_bytes, initial_visited, [])
        |> Enum.reverse()

      _ ->
        []
    end
  end

  defp walk_dir(dir, contain_root?, canonical_root, max_file_bytes, visited_dirs, acc) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce(acc, fn name, inner_acc ->
          entry_path = Path.join(dir, name)

          walk_entry(
            name,
            entry_path,
            contain_root?,
            canonical_root,
            max_file_bytes,
            visited_dirs,
            inner_acc
          )
        end)

      {:error, _} ->
        acc
    end
  end

  defp walk_entry(
         name,
         entry_path,
         contain_root?,
         canonical_root,
         max_file_bytes,
         visited_dirs,
         acc
       ) do
    case File.lstat(entry_path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        if size <= max_file_bytes and elixir_file?(name) do
          [entry_path | acc]
        else
          acc
        end

      {:ok, %File.Stat{type: :directory}} ->
        if MapSet.member?(@excluded_dir_names, name) do
          acc
        else
          recurse_dir(
            entry_path,
            contain_root?,
            canonical_root,
            max_file_bytes,
            visited_dirs,
            acc
          )
        end

      {:ok, %File.Stat{type: :symlink}} ->
        handle_symlink_entry(
          name,
          entry_path,
          contain_root?,
          canonical_root,
          max_file_bytes,
          visited_dirs,
          acc
        )

      _ ->
        acc
    end
  end

  defp recurse_dir(dir_path, contain_root?, canonical_root, max_file_bytes, visited_dirs, acc) do
    case canonical_dir_key(dir_path) do
      {:ok, key} ->
        if MapSet.member?(visited_dirs, key) do
          acc
        else
          walk_dir(
            dir_path,
            contain_root?,
            canonical_root,
            max_file_bytes,
            MapSet.put(visited_dirs, key),
            acc
          )
        end

      :error ->
        acc
    end
  end

  defp handle_symlink_entry(
         name,
         entry_path,
         true = _contain_root?,
         canonical_root,
         max_file_bytes,
         visited_dirs,
         acc
       )
       when is_binary(canonical_root) do
    case resolve_within_root(canonical_root, entry_path) do
      {:ok, resolved} ->
        if inside_excluded_dir?(resolved, canonical_root) do
          acc
        else
          case File.stat(resolved) do
            {:ok, %File.Stat{type: :regular, size: size}} ->
              if size <= max_file_bytes and elixir_file?(name) do
                [entry_path | acc]
              else
                acc
              end

            {:ok, %File.Stat{type: :directory}} ->
              if MapSet.member?(@excluded_dir_names, name) do
                acc
              else
                recurse_dir(entry_path, true, canonical_root, max_file_bytes, visited_dirs, acc)
              end

            _ ->
              acc
          end
        end

      {:error, _reason} ->
        Logger.warning("ASTSearch: skipping symlink escaping root: #{entry_path}")
        acc
    end
  end

  defp handle_symlink_entry(
         name,
         entry_path,
         false = _contain_root?,
         canonical_root,
         max_file_bytes,
         visited_dirs,
         acc
       ) do
    case File.stat(entry_path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        if size <= max_file_bytes and elixir_file?(name) do
          [entry_path | acc]
        else
          acc
        end

      {:ok, %File.Stat{type: :directory}} ->
        if MapSet.member?(@excluded_dir_names, name) do
          acc
        else
          recurse_dir(entry_path, false, canonical_root, max_file_bytes, visited_dirs, acc)
        end

      _ ->
        acc
    end
  end

  defp inside_excluded_dir?(path, canonical_root) do
    path
    |> Path.relative_to(canonical_root)
    |> Path.split()
    |> Enum.any?(&MapSet.member?(@excluded_dir_names, &1))
  end

  defp canonical_dir_key(dir_path) do
    case File.stat(dir_path) do
      {:ok, %File.Stat{major_device: dev, inode: ino}} when ino != 0 ->
        {:ok, {dev, ino}}

      {:ok, _stat} ->
        {:ok, Path.expand(dir_path)}

      {:error, _} ->
        :error
    end
  end

  defp elixir_file?(name) do
    Path.extname(name) in @elixir_extensions
  end

  defp extract_file_symbols(file_path, rel_path, max_file_bytes) do
    try do
      case File.stat(file_path) do
        {:ok, %File.Stat{size: size}} when size > max_file_bytes ->
          []

        {:ok, _stat} ->
          case File.read(file_path) do
            {:ok, content} when byte_size(content) <= max_file_bytes ->
              case Extractor.extract(content, rel_path) do
                {:ok, symbols} ->
                  symbols

                {:error, reason} ->
                  Logger.warning(
                    "ASTSearch: skipping #{rel_path}: parse error #{inspect(reason)}"
                  )

                  []
              end

            {:ok, _oversized} ->
              []

            {:error, reason} ->
              Logger.warning("ASTSearch: skipping #{rel_path}: read error #{inspect(reason)}")
              []
          end

        {:error, reason} ->
          Logger.warning("ASTSearch: skipping #{rel_path}: stat error #{inspect(reason)}")
          []
      end
    rescue
      e ->
        Logger.warning("ASTSearch: skipping #{rel_path}: #{Exception.message(e)}")
        []
    end
  end

  # Relative path for display; falls back to the absolute path when the file
  # lives outside `project_root` (possible with absolute path queries when contain_root: false).
  defp relative_path(file_path, project_root, canonical_root) do
    root = project_root |> to_string() |> String.trim_trailing("/")
    canon = if is_binary(canonical_root), do: String.trim_trailing(canonical_root, "/"), else: nil

    cond do
      file_path == root ->
        Path.basename(file_path)

      String.starts_with?(file_path, root <> "/") ->
        Path.relative_to(file_path, root)

      is_binary(canon) and file_path == canon ->
        Path.basename(file_path)

      is_binary(canon) and String.starts_with?(file_path, canon <> "/") ->
        Path.relative_to(file_path, canon)

      true ->
        file_path
    end
  end
end

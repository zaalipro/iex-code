defmodule IexCode.Tools.ASTSearch do
  @moduledoc """
  AST-Aware Search Engine for Elixir projects.
  Traverses Elixir source code AST to locate modules, functions, macros,
  @spec type signatures, @doc/@moduledoc documentation, and module attributes.
  """

  alias IexCode.Tools.ASTSearch.{Extractor, Query, Formatter}

  @type symbol_entry :: Extractor.symbol_entry()
  @type query_spec :: String.t() | map() | keyword()

  @doc """
  Searches all .ex/.exs files in `project_root` matching `query`.
  """
  @spec search(Path.t(), query_spec(), keyword()) ::
          {:ok, [symbol_entry()]} | {:error, term()}
  def search(project_root, query, opts \\ []) do
    sub_path =
      case query do
        %{path: p} when is_binary(p) and p != "" -> p
        %{"path" => p} when is_binary(p) and p != "" -> p
        _ -> Keyword.get(opts, :path, "")
      end

    search_dir =
      if sub_path != "" and Path.type(sub_path) != :absolute do
        Path.join(project_root, sub_path)
      else
        project_root
      end

    if File.exists?(search_dir) do
      files = find_elixir_files(search_dir)

      all_symbols =
        Enum.flat_map(files, fn file_path ->
          rel_path = Path.relative_to(file_path, project_root)

          case File.read(file_path) do
            {:ok, content} ->
              case Extractor.extract(content, rel_path) do
                {:ok, symbols} -> symbols
                _ -> []
              end

            _ ->
              []
          end
        end)

      filtered = Query.filter(all_symbols, query)
      {:ok, filtered}
    else
      {:error, :path_not_found}
    end
  end

  @doc """
  Searches a single source file for AST symbols matching `query`.
  """
  @spec search_file(Path.t(), query_spec(), keyword()) ::
          {:ok, [symbol_entry()]} | {:error, term()}
  def search_file(file_path, query, _opts \\ []) do
    if File.exists?(file_path) do
      case File.read(file_path) do
        {:ok, content} ->
          case Extractor.extract(content, file_path) do
            {:ok, symbols} ->
              {:ok, Query.filter(symbols, query)}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :file_not_found}
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

  # --- File Discovery Helpers ---

  defp find_elixir_files(dir) do
    if File.regular?(dir) do
      [dir]
    else
      Path.wildcard(Path.join(dir, "**/*.{ex,exs}"))
      |> Enum.reject(fn p ->
        String.contains?(p, "/_build/") or
          String.contains?(p, "/deps/") or
          String.contains?(p, "/.git/") or
          String.contains?(p, "/.agents/") or
          String.contains?(p, "/node_modules/")
      end)
    end
  end
end

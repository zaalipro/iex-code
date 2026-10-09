defmodule IexCode.Tools.NativeGrep do
  @moduledoc false
  alias IexCode.Tools.BoundedFile
  alias IexCode.Tools.BoundedDirectory
  alias IexCode.Tools.NativeResponse
  alias IexCode.WorkspacePath

  @excluded_dirs ["_build", "deps", "node_modules", ".git"]
  @excluded_extensions ~w(.db .db-wal .db-shm .beam .png .jpg .jpeg .ico .svg .lock .dump .gz .zip)
  @entries 5_000
  @files 500
  @matches 100
  @scan_bytes 8_388_608
  @depth 64
  @query_bytes 4_096
  @pending_bytes 2_097_152

  def validate_query(query) when is_binary(query) and byte_size(query) <= @query_bytes, do: :ok
  def validate_query(_), do: {:error, "Query exceeds 4096 bytes; use a shorter query."}

  def search(root, directory, query, case_sensitive?) do
    with :ok <- validate_query(query),
         {:ok, root} <- WorkspacePath.resolve(root, "") do
      do_search(root, directory, query, case_sensitive?)
    end
  end

  defp do_search(root, directory, query, case_sensitive?) do
    case BoundedDirectory.open() do
      {:ok, helper} ->
        try do
          run_search(root, directory, query, case_sensitive?, helper)
        after
          BoundedDirectory.close(helper)
        end

      {:error, _} ->
        {:error, "Directory helper unavailable; cannot complete bounded search."}
    end
  end

  defp run_search(root, directory, query, case_sensitive?, helper) do
    state = %{
      helper: helper,
      wire: 0,
      helper_rss: 0,
      results: [],
      matches: 0,
      output: 0,
      files: 0,
      entries: 0,
      bytes: 0,
      reasons: MapSet.new()
    }

    state =
      walk(
        [{directory, :directory, 0}],
        root,
        matcher(query, case_sensitive?),
        case_sensitive?,
        state
      )

    body =
      if state.results == [] do
        if MapSet.size(state.reasons) == 0,
          do: "No matches found for '#{query}'",
          else: "No matches in the scanned portion."
      else
        state.results |> Enum.reverse() |> Enum.join("\n")
      end

    suffix =
      if MapSet.size(state.reasons) == 0 do
        ""
      else
        reasons = state.reasons |> Enum.sort() |> Enum.join(", ")

        "\n[truncated/incomplete: #{reasons}. Scanned #{state.files} eligible files, " <>
          "#{state.bytes} bytes. Use a narrower path/query or split oversized files/lines.]"
      end

    output = NativeResponse.compose(body, suffix)

    :telemetry.execute(
      [:iex_code, :tools, :native_scan],
      %{
        scanned_bytes: state.bytes,
        output_bytes: byte_size(output),
        output_matches: state.matches,
        eligible_files: state.files,
        traversal_entries: state.entries,
        directory_wire_bytes: state.wire,
        helper_peak_rss_bytes: state.helper_rss,
        helper_launches: 1
      },
      %{tool: :grep_search}
    )

    {:ok, output, state.matches}
  end

  defp walk([], _root, _matcher, _case, state), do: state

  defp walk(_pending, _root, _matcher, _case, %{matches: @matches} = state),
    do: incomplete(state, "100 total matches")

  defp walk(_pending, _root, _matcher, _case, %{files: @files} = state),
    do: incomplete(state, "500 eligible files")

  defp walk(_pending, _root, _matcher, _case, %{entries: entries} = state)
       when entries >= @entries,
       do: incomplete(state, "traversal entry limit")

  defp walk(_pending, _root, _matcher, _case, %{bytes: bytes} = state) when bytes >= @scan_bytes,
    do: incomplete(state, "global scan byte limit")

  defp walk([{path, type, depth} | rest], root, matcher, case_sensitive?, state) do
    with {:ok, canonical} <- WorkspacePath.resolve(root, path),
         {:ok, %{type: actual}} <- File.stat(canonical) do
      case {type, actual} do
        {:directory, :directory} ->
          if depth >= @depth do
            walk(rest, root, matcher, case_sensitive?, incomplete(state, "traversal depth limit"))
          else
            case BoundedDirectory.list(
                   state.helper,
                   canonical,
                   @entries - state.entries,
                   BoundedDirectory.wire_bytes() - state.wire
                 ) do
              {:ok, names, stats} ->
                state = charge_directory(state, stats)

                case add_candidates(names, path, depth + 1, rest) do
                  {:ok, pending} ->
                    walk(Enum.sort_by(pending, &order/1), root, matcher, case_sensitive?, state)

                  :overflow ->
                    incomplete(state, "pending path byte limit")
                end

              {:incomplete, reason, stats} ->
                state |> charge_directory(stats) |> incomplete(directory_reason(reason))

              {:skip, stats} ->
                walk(rest, root, matcher, case_sensitive?, charge_directory(state, stats))

              {:error, _} ->
                incomplete(state, "directory helper timeout/failure")
            end
          end

        {:file, :regular} ->
          state = scan(canonical, Path.relative_to(path, root), matcher, case_sensitive?, state)

          if MapSet.member?(state.reasons, "output byte limit") do
            state
          else
            walk(rest, root, matcher, case_sensitive?, state)
          end

        _ ->
          walk(rest, root, matcher, case_sensitive?, state)
      end
    else
      _ -> walk(rest, root, matcher, case_sensitive?, state)
    end
  end

  defp charge_directory(state, stats) do
    %{
      state
      | entries: state.entries + stats.entries,
        wire: state.wire + stats.wire_bytes,
        helper_rss: max(state.helper_rss, stats.helper_peak_rss_bytes)
    }
  end

  defp directory_reason(:entries), do: "traversal entry limit"
  defp directory_reason(:wire), do: "directory wire byte limit"
  defp directory_reason(:name), do: "directory name byte limit"

  defp add_candidates(names, path, depth, rest) do
    bytes = Enum.reduce(rest, 0, fn {name, _, _}, size -> size + byte_size(name) end)

    Enum.reduce_while(names, {:ok, rest, bytes}, fn name, {:ok, pending, bytes} ->
      case candidate(path, name, depth) do
        [] ->
          {:cont, {:ok, pending, bytes}}

        [{child, _, _} = candidate] ->
          bytes = bytes + byte_size(child)

          if bytes > @pending_bytes,
            do: {:halt, :overflow},
            else: {:cont, {:ok, [candidate | pending], bytes}}
      end
    end)
    |> case do
      {:ok, pending, _bytes} -> {:ok, pending}
      :overflow -> :overflow
    end
  end

  defp candidate(parent, name, depth) do
    path = Path.join(parent, name)

    if name in @excluded_dirs or String.starts_with?(name, ".") do
      []
    else
      case File.lstat(path) do
        {:ok, %{type: :directory}} ->
          [{path, :directory, depth}]

        # Directory symlinks are never descended, including inward cycles.
        {:ok, %{type: type}} when type in [:regular, :symlink] ->
          if String.downcase(Path.extname(name)) in @excluded_extensions,
            do: [],
            else: [{path, :file, depth}]

        _ ->
          []
      end
    end
  end

  defp order({path, :directory, _depth}), do: path <> "/"
  defp order({path, :file, _depth}), do: path

  defp scan(path, relative, matcher, case_sensitive?, state) do
    limit = min(BoundedFile.limits().scan_bytes, @scan_bytes - state.bytes)
    initial = %{results: [], matches: 0, bytes: 0}

    callback = fn line, index, acc ->
      if matches?(line, matcher, case_sensitive?) do
        text = "#{relative}:#{index}: #{String.trim(line)}"
        bytes = byte_size(text) + 1

        if state.output + acc.bytes + bytes > NativeResponse.body_bytes() do
          {:validate, :output, acc}
        else
          acc = %{
            results: [text | acc.results],
            matches: acc.matches + 1,
            bytes: acc.bytes + bytes
          }

          cond do
            state.output + acc.bytes == NativeResponse.body_bytes() -> {:validate, :output, acc}
            acc.matches == min(10, @matches - state.matches) -> {:validate, :matches, acc}
            true -> {:cont, acc}
          end
        end
      else
        {:cont, acc}
      end
    end

    case BoundedFile.scan(path, initial, callback, byte_limit: limit, valid_utf8: true) do
      {:ok, result} ->
        state = %{
          state
          | files: state.files + 1,
            bytes: state.bytes + result.bytes,
            results: result.acc.results ++ state.results,
            matches: state.matches + result.acc.matches,
            output: state.output + result.acc.bytes
        }

        state =
          case result.collection_reason do
            :output -> incomplete(state, "output byte limit")
            :matches -> incomplete(state, "10 matches/file or total match limit")
            nil -> state
          end

        case result.reason do
          nil -> state
          :matches -> incomplete(state, "10 matches/file or total match limit")
          :output -> incomplete(state, "output byte limit")
          :scan -> incomplete(state, "file scan byte limit; tail unvalidated")
          :giant_line -> incomplete(state, "giant line limit; tail unvalidated")
        end

      {:error, _reason, bytes} ->
        # Invalid UTF-8 and unreadable candidates retain their existing skip behavior.
        %{state | files: state.files + 1, bytes: state.bytes + bytes}

      {:error, _reason} ->
        %{state | files: state.files + 1}
    end
  end

  defp incomplete(state, reason), do: %{state | reasons: MapSet.put(state.reasons, reason)}

  defp matcher(query, case_sensitive?) do
    case Regex.compile(query, if(case_sensitive?, do: "", else: "i")) do
      {:ok, regex} -> {:regex, regex}
      {:error, _} -> {:text, if(case_sensitive?, do: query, else: String.downcase(query))}
    end
  end

  defp matches?(line, {:regex, regex}, _case), do: Regex.match?(regex, line)
  defp matches?(line, {:text, needle}, true), do: String.contains?(line, needle)
  defp matches?(line, {:text, needle}, _case), do: String.contains?(String.downcase(line), needle)
end

defmodule IexCode.Tools.NativeGrep do
  @moduledoc false
  alias IexCode.Tools.BoundedFile
  alias IexCode.WorkspacePath

  @excluded_dirs ["_build", "deps", "node_modules", ".git"]
  @excluded_extensions ~w(.db .db-wal .db-shm .beam .png .jpg .jpeg .ico .svg .lock .dump .gz .zip)
  @entries 5_000
  @files 500
  @matches 100
  @scan_bytes 8_388_608
  @depth 64

  def search(root, directory, query, case_sensitive?) do
    state = %{
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

    output = body <> suffix

    :telemetry.execute(
      [:iex_code, :tools, :native_scan],
      %{
        scanned_bytes: state.bytes,
        output_bytes: byte_size(output),
        output_matches: state.matches,
        eligible_files: state.files,
        traversal_entries: state.entries
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
    state = %{state | entries: state.entries + 1}

    with {:ok, canonical} <- WorkspacePath.resolve(root, path),
         {:ok, %{type: actual}} <- File.stat(canonical) do
      case {type, actual} do
        {:directory, :directory} ->
          if depth >= @depth do
            walk(rest, root, matcher, case_sensitive?, incomplete(state, "traversal depth limit"))
          else
            case File.ls(canonical) do
              {:ok, names} ->
                remaining = @entries - state.entries - length(rest)

                if length(names) > remaining do
                  incomplete(state, "traversal entry limit")
                else
                  children = Enum.flat_map(names, &candidate(path, &1, depth + 1))
                  pending = Enum.sort_by(children ++ rest, &order/1)
                  walk(pending, root, matcher, case_sensitive?, state)
                end

              {:error, _} ->
                walk(rest, root, matcher, case_sensitive?, state)
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

  defp candidate(parent, name, depth) do
    path = Path.join(parent, name)

    if name in @excluded_dirs or String.starts_with?(name, ".") or
         String.downcase(Path.extname(name)) in @excluded_extensions do
      []
    else
      case File.lstat(path) do
        {:ok, %{type: :directory}} -> [{path, :directory, depth}]
        # Directory symlinks are never descended, including inward cycles.
        {:ok, %{type: type}} when type in [:regular, :symlink] -> [{path, :file, depth}]
        _ -> []
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

        if state.output + acc.bytes + bytes > BoundedFile.limits().output_bytes do
          {:halt, :output, acc}
        else
          acc = %{
            results: [text | acc.results],
            matches: acc.matches + 1,
            bytes: acc.bytes + bytes
          }

          if acc.matches == min(10, @matches - state.matches),
            do: {:halt, :matches, acc},
            else: {:cont, acc}
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

        case result.reason do
          nil -> state
          :matches -> incomplete(state, "10 matches/file or total match limit")
          :output -> incomplete(state, "output byte limit")
          :scan -> incomplete(state, "file scan byte limit")
          :giant_line -> incomplete(state, "giant line limit")
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

defmodule IexCode.Tools.Git.DiffParser do
  @moduledoc """
  Pure Elixir parser converting unified diff strings (`git diff`, `patch`) into
  structured `%FileDiff{}` and `%Hunk{}` records.

  Robustly handles:
  - Standard modified files with multiple hunks
  - New files (`--- /dev/null`, `+++ b/file`, `new file mode`)
  - Deleted files (`--- a/file`, `+++ /dev/null`, `deleted file mode`)
  - Renamed files (`similarity index`, `rename from`, `rename to`)
  - Binary files (`Binary files a/... and b/... differ`, `GIT binary patch`)
  - Missing newlines at EOF (`\\ No newline at end of file`)
  - Hunks with omitted line counts (`@@ -1 +1 @@`)
  - Sequential line numbering for deletions, additions, and context lines
  """

  defmodule Line do
    @moduledoc """
    Individual line in a diff hunk.
    """
    @type line_type :: :context | :addition | :deletion | :eof_newline | :header
    @type t :: %__MODULE__{
            type: line_type(),
            content: String.t(),
            old_num: integer() | nil,
            new_num: integer() | nil
          }
    defstruct [:type, :content, :old_num, :new_num]
  end

  defmodule Hunk do
    @moduledoc """
    Structured diff hunk entity with line range boundaries and lines.
    """
    alias IexCode.Tools.Git.DiffParser.Line

    @type status :: :pending | :accepted | :rejected
    @type t :: %__MODULE__{
            id: String.t(),
            file_path: String.t() | nil,
            header: String.t(),
            lines: [Line.t()],
            old_start: integer(),
            old_lines: integer(),
            new_start: integer(),
            new_lines: integer(),
            old_count: integer(),
            new_count: integer(),
            status: status()
          }
    defstruct [
      :id,
      :file_path,
      :header,
      :old_start,
      :old_lines,
      :new_start,
      :new_lines,
      old_count: 0,
      new_count: 0,
      lines: [],
      status: :pending
    ]
  end

  defmodule FileDiff do
    @moduledoc """
    Structured representation of all diff hunks and metadata for a single file.
    """
    alias IexCode.Tools.Git.DiffParser.Hunk

    @type diff_status :: :modified | :added | :deleted | :renamed | :binary | :copied
    @type t :: %__MODULE__{
            path: String.t(),
            old_path: String.t() | nil,
            new_path: String.t() | nil,
            status: diff_status(),
            hunks: [Hunk.t()],
            additions: non_neg_integer(),
            deletions: non_neg_integer(),
            binary?: boolean()
          }
    defstruct [
      :path,
      :old_path,
      :new_path,
      :status,
      hunks: [],
      additions: 0,
      deletions: 0,
      binary?: false
    ]
  end

  alias __MODULE__.{Line, Hunk, FileDiff}

  @hunk_header_regex ~r/^@@\s+-(\d+)(?:,(\d+))?\s+\+(\d+)(?:,(\d+))?\s+@@(?: *(.*))?$/

  @doc """
  Parses a raw unified diff string into a list of `%FileDiff{}` structs.
  Returns `{:ok, [FileDiff.t()]}`.
  """
  @spec parse(String.t() | nil) :: {:ok, [FileDiff.t()]}
  def parse(nil), do: {:ok, []}

  def parse(raw_diff) when is_binary(raw_diff) do
    if String.trim(raw_diff) == "" do
      {:ok, []}
    else
      file_chunks = split_into_file_chunks(raw_diff)
      parsed_files = Enum.map(file_chunks, &parse_file_chunk/1)
      {:ok, parsed_files}
    end
  end

  @doc """
  Parses a raw unified diff string, returning the list of `%FileDiff{}` directly.
  """
  @spec parse!(String.t() | nil) :: [FileDiff.t()]
  def parse!(raw_diff) do
    {:ok, files} = parse(raw_diff)
    files
  end

  @doc """
  Finds a specific hunk within a `%FileDiff{}` or a list of `%FileDiff{}` structs.
  Matches by hunk `id` or string/integer index.
  """
  @spec find_hunk([FileDiff.t()] | FileDiff.t(), String.t() | integer()) ::
          {:ok, {FileDiff.t(), Hunk.t()}} | {:error, :hunk_not_found}
  def find_hunk(%FileDiff{} = file_diff, hunk_id) do
    find_hunk([file_diff], hunk_id)
  end

  def find_hunk(file_diffs, hunk_id) when is_list(file_diffs) do
    id_str = to_string(hunk_id)

    result =
      Enum.find_value(file_diffs, fn file_diff ->
        matching_hunk =
          Enum.find(file_diff.hunks, fn hunk ->
            hunk.id == id_str or
              hunk.id == "hunk-#{id_str}" or
              String.ends_with?(hunk.id, "-#{id_str}") or
              hunk.header == id_str
          end) ||
            if is_integer(hunk_id) or Regex.match?(~r/^\d+$/, id_str) do
              idx = if is_integer(hunk_id), do: hunk_id, else: String.to_integer(id_str)
              Enum.at(file_diff.hunks, idx - 1) || Enum.at(file_diff.hunks, idx)
            end

        if matching_hunk, do: {file_diff, matching_hunk}
      end)

    case result do
      {file_diff, hunk} -> {:ok, {file_diff, hunk}}
      nil -> {:error, :hunk_not_found}
    end
  end

  @doc """
  Generates a standalone unified diff patch string for a single hunk.
  The output can be directly passed to `git apply`, `git apply --cached`, or `git apply --reverse`.
  """
  @spec format_hunk_patch(Hunk.t()) :: String.t()
  @spec format_hunk_patch(FileDiff.t(), Hunk.t()) :: String.t()
  def format_hunk_patch(%Hunk{} = hunk) do
    file_path = hunk.file_path || "file"

    file_diff = %FileDiff{
      path: file_path,
      old_path: file_path,
      new_path: file_path,
      status: :modified
    }

    format_hunk_patch(file_diff, hunk)
  end

  def format_hunk_patch(%FileDiff{} = file_diff, %Hunk{} = hunk) do
    old_path = file_diff.old_path || file_diff.path || hunk.file_path || "a"
    new_path = file_diff.new_path || file_diff.path || hunk.file_path || "b"

    header_lines =
      cond do
        file_diff.status == :added or is_nil(file_diff.old_path) ->
          [
            "diff --git a/#{new_path} b/#{new_path}",
            "new file mode 100644",
            "--- /dev/null",
            "+++ b/#{new_path}"
          ]

        file_diff.status == :deleted or is_nil(file_diff.new_path) ->
          [
            "diff --git a/#{old_path} b/#{old_path}",
            "deleted file mode 100644",
            "--- a/#{old_path}",
            "+++ /dev/null"
          ]

        file_diff.status == :renamed and old_path != new_path ->
          [
            "diff --git a/#{old_path} b/#{new_path}",
            "rename from #{old_path}",
            "rename to #{new_path}",
            "--- a/#{old_path}",
            "+++ b/#{new_path}"
          ]

        true ->
          [
            "diff --git a/#{old_path} b/#{new_path}",
            "--- a/#{old_path}",
            "+++ b/#{new_path}"
          ]
      end

    hunk_header =
      "@@ -#{hunk.old_start},#{hunk.old_lines} +#{hunk.new_start},#{hunk.new_lines} @@"

    body_lines =
      Enum.map(hunk.lines, fn line ->
        case line.type do
          :addition -> "+#{line.content}"
          :deletion -> "-#{line.content}"
          :context -> " #{line.content}"
          :eof_newline -> line.content
          _ -> " #{line.content}"
        end
      end)

    (header_lines ++ [hunk_header | body_lines])
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @doc """
  Calculates aggregate summary metrics from a list of `%FileDiff{}` structs.
  """
  @spec summary([FileDiff.t()]) :: %{
          files_count: non_neg_integer(),
          additions: non_neg_integer(),
          deletions: non_neg_integer(),
          hunks_count: non_neg_integer()
        }
  def summary(file_diffs) when is_list(file_diffs) do
    files_count = length(file_diffs)

    additions =
      Enum.reduce(file_diffs, 0, fn f, acc -> acc + f.additions end)

    deletions =
      Enum.reduce(file_diffs, 0, fn f, acc -> acc + f.deletions end)

    hunks_count =
      Enum.reduce(file_diffs, 0, fn f, acc -> acc + length(f.hunks) end)

    %{
      files_count: files_count,
      additions: additions,
      deletions: deletions,
      hunks_count: hunks_count
    }
  end

  # --- Internal Parsing Logic ---

  defp split_into_file_chunks(raw_diff) do
    lines = String.split(raw_diff, ~r/\r?\n/)

    {chunks, current_chunk} =
      Enum.reduce(lines, {[], []}, fn line, {acc_chunks, current_lines} ->
        if is_file_boundary?(line, current_lines) do
          {[Enum.reverse(current_lines) | acc_chunks], [line]}
        else
          {acc_chunks, [line | current_lines]}
        end
      end)

    all_chunks =
      if current_chunk != [] do
        [Enum.reverse(current_chunk) | chunks]
      else
        chunks
      end
      |> Enum.reverse()
      |> Enum.reject(&(&1 == [] or Enum.all?(&1, fn l -> String.trim(l) == "" end)))

    all_chunks
  end

  defp is_file_boundary?(line, current_lines) do
    cond do
      current_lines == [] ->
        false

      String.starts_with?(line, "diff --git ") ->
        true

      String.starts_with?(line, "--- ") and
        not Enum.any?(current_lines, &String.starts_with?(&1, "diff --git ")) and
          Enum.any?(current_lines, &String.starts_with?(&1, "+++ ")) ->
        true

      true ->
        false
    end
  end

  defp parse_file_chunk(lines) do
    {header_lines, hunk_lines} =
      Enum.split_while(lines, fn line ->
        not String.starts_with?(line, "@@")
      end)

    file_diff = parse_file_headers(header_lines)
    hunks = parse_hunks(hunk_lines, file_diff.path)

    additions =
      Enum.reduce(hunks, 0, fn hunk, acc ->
        acc + Enum.count(hunk.lines, &(&1.type == :addition))
      end)

    deletions =
      Enum.reduce(hunks, 0, fn hunk, acc ->
        acc + Enum.count(hunk.lines, &(&1.type == :deletion))
      end)

    status =
      cond do
        file_diff.binary? ->
          :binary

        file_diff.status != nil ->
          file_diff.status

        file_diff.old_path == nil and file_diff.new_path != nil ->
          :added

        file_diff.old_path != nil and file_diff.new_path == nil ->
          :deleted

        file_diff.old_path != nil and file_diff.new_path != nil and
            file_diff.old_path != file_diff.new_path ->
          :renamed

        true ->
          :modified
      end

    resolved_path = file_diff.new_path || file_diff.old_path || file_diff.path || "unknown"
    old_path = if status == :added, do: nil, else: file_diff.old_path || resolved_path
    new_path = if status == :deleted, do: nil, else: file_diff.new_path || resolved_path
    primary_path = if status == :deleted, do: old_path, else: new_path || resolved_path

    %{
      file_diff
      | path: primary_path,
        old_path: old_path,
        new_path: new_path,
        hunks: hunks,
        additions: additions,
        deletions: deletions,
        status: status
    }
  end

  defp parse_file_headers(header_lines) do
    Enum.reduce(header_lines, %FileDiff{status: nil}, fn line, acc ->
      cond do
        String.starts_with?(line, "diff --git ") ->
          {old_p, new_p} = parse_diff_git_paths(line)
          %{acc | old_path: old_p, new_path: new_p, path: new_p || old_p}

        String.starts_with?(line, "--- ") ->
          path = parse_header_path(line, "--- ")
          old_p = if path == "/dev/null", do: nil, else: path
          new_status = if path == "/dev/null", do: :added, else: acc.status
          %{acc | old_path: old_p, status: new_status}

        String.starts_with?(line, "+++ ") ->
          path = parse_header_path(line, "+++ ")
          new_p = if path == "/dev/null", do: nil, else: path
          new_status = if path == "/dev/null", do: :deleted, else: acc.status
          %{acc | new_path: new_p, path: new_p || acc.path, status: new_status}

        String.starts_with?(line, "new file mode") ->
          %{acc | status: :added}

        String.starts_with?(line, "deleted file mode") ->
          %{acc | status: :deleted}

        String.starts_with?(line, "similarity index ") ->
          %{acc | status: :renamed}

        String.starts_with?(line, "rename from ") ->
          old_p = clean_path(String.replace_prefix(line, "rename from ", ""))
          %{acc | old_path: old_p, status: :renamed}

        String.starts_with?(line, "rename to ") ->
          new_p = clean_path(String.replace_prefix(line, "rename to ", ""))
          %{acc | new_path: new_p, path: new_p, status: :renamed}

        String.starts_with?(line, "Binary files ") or String.contains?(line, "GIT binary patch") ->
          %{acc | binary?: true, status: :binary}

        true ->
          acc
      end
    end)
  end

  defp parse_diff_git_paths(line) do
    rest = String.replace_prefix(line, "diff --git ", "")

    case Regex.run(~r/^(?:"a\/(.*?)"|a\/(.*?))\s+(?:"b\/(.*?)"|b\/(.*?))$/, rest) do
      [_, q1, u1, q2, u2] ->
        old_p = if q1 != "", do: q1, else: u1
        new_p = if q2 != "", do: q2, else: u2
        {clean_path(old_p), clean_path(new_p)}

      _ ->
        case String.split(rest, " ") do
          [a, b] -> {clean_path(a), clean_path(b)}
          _ -> {nil, nil}
        end
    end
  end

  defp parse_header_path(line, prefix) do
    raw = String.replace_prefix(line, prefix, "") |> String.trim()
    path_part = raw |> String.split("\t") |> List.first() |> String.trim()
    clean_path(path_part)
  end

  defp clean_path(nil), do: nil
  defp clean_path(""), do: nil
  defp clean_path("/dev/null"), do: "/dev/null"

  defp clean_path(path) do
    path
    |> String.trim("\"")
    |> clean_prefix("a/")
    |> clean_prefix("b/")
  end

  defp clean_prefix(path, prefix) do
    if String.starts_with?(path, prefix) do
      String.replace_prefix(path, prefix, "")
    else
      path
    end
  end

  defp parse_hunks(lines, file_path) do
    {hunk_chunks, current_hunk} =
      Enum.reduce(lines, {[], []}, fn line, {acc_chunks, current_lines} ->
        if String.starts_with?(line, "@@") and current_lines != [] do
          {[Enum.reverse(current_lines) | acc_chunks], [line]}
        else
          {acc_chunks, [line | current_lines]}
        end
      end)

    all_hunk_chunks =
      if current_hunk != [] do
        [Enum.reverse(current_hunk) | hunk_chunks]
      else
        hunk_chunks
      end
      |> Enum.reverse()

    all_hunk_chunks
    |> Enum.with_index(1)
    |> Enum.map(fn {hunk_lines, index} ->
      parse_single_hunk(hunk_lines, file_path, index)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_single_hunk([], _file_path, _index), do: nil

  defp parse_single_hunk([header_line | body_lines], file_path, index) do
    case Regex.run(@hunk_header_regex, header_line) do
      [_, os_str, ol_str, ns_str, nl_str | _] ->
        old_start = String.to_integer(os_str)
        old_lines = if ol_str != "", do: String.to_integer(ol_str), else: 1
        new_start = String.to_integer(ns_str)
        new_lines = if nl_str != "", do: String.to_integer(nl_str), else: 1

        hunk_id = "hunk-#{index}"

        trimmed_body = reject_trailing_empty(body_lines)

        {lines, _final_old, _final_new} =
          Enum.reduce(trimmed_body, {[], old_start, new_start}, fn line,
                                                                   {acc_lines, cur_old, cur_new} ->
            case line do
              "+" <> content ->
                line_struct = %Line{
                  type: :addition,
                  content: content,
                  old_num: nil,
                  new_num: cur_new
                }

                {[line_struct | acc_lines], cur_old, cur_new + 1}

              "-" <> content ->
                line_struct = %Line{
                  type: :deletion,
                  content: content,
                  old_num: cur_old,
                  new_num: nil
                }

                {[line_struct | acc_lines], cur_old + 1, cur_new}

              " " <> content ->
                line_struct = %Line{
                  type: :context,
                  content: content,
                  old_num: cur_old,
                  new_num: cur_new
                }

                {[line_struct | acc_lines], cur_old + 1, cur_new + 1}

              "\\ No newline" <> _ = marker ->
                line_struct = %Line{
                  type: :eof_newline,
                  content: marker,
                  old_num: nil,
                  new_num: nil
                }

                {[line_struct | acc_lines], cur_old, cur_new}

              "" ->
                line_struct = %Line{
                  type: :context,
                  content: "",
                  old_num: cur_old,
                  new_num: cur_new
                }

                {[line_struct | acc_lines], cur_old + 1, cur_new + 1}

              other ->
                line_struct = %Line{
                  type: :context,
                  content: other,
                  old_num: cur_old,
                  new_num: cur_new
                }

                {[line_struct | acc_lines], cur_old + 1, cur_new + 1}
            end
          end)

        %Hunk{
          id: hunk_id,
          file_path: file_path,
          header: header_line,
          old_start: old_start,
          old_lines: old_lines,
          new_start: new_start,
          new_lines: new_lines,
          old_count: old_lines,
          new_count: new_lines,
          lines: Enum.reverse(lines),
          status: :pending
        }

      _ ->
        nil
    end
  end

  defp reject_trailing_empty(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end
end

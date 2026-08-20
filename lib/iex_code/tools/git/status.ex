defmodule IexCode.Tools.Git.StatusResult do
  @moduledoc """
  Structured Git status representation.
  """
  @type file_status :: :modified | :added | :deleted | :renamed | :copied | :conflict
  @type staged_entry :: %{
          path: String.t(),
          status: file_status(),
          old_path: String.t() | nil
        }
  @type unstaged_entry :: %{
          path: String.t(),
          status: :modified | :deleted
        }
  @type conflict_entry :: %{
          path: String.t(),
          status: :conflict,
          code: String.t()
        }

  @type t :: %__MODULE__{
          branch: String.t(),
          upstream: String.t() | nil,
          ahead: non_neg_integer(),
          behind: non_neg_integer(),
          initial?: boolean(),
          staged: [staged_entry()],
          unstaged: [unstaged_entry()],
          untracked: [String.t()],
          conflicted: [conflict_entry()],
          clean?: boolean()
        }
  defstruct branch: "main",
            upstream: nil,
            ahead: 0,
            behind: 0,
            initial?: false,
            staged: [],
            unstaged: [],
            untracked: [],
            conflicted: [],
            clean?: true
end

defmodule IexCode.Tools.Git.CommitResult do
  @moduledoc """
  Structured commit creation result.
  """
  @type t :: %__MODULE__{
          commit_hash: String.t(),
          short_hash: String.t(),
          message: String.t(),
          author: String.t() | nil,
          timestamp: DateTime.t() | nil
        }
  defstruct [:commit_hash, :short_hash, :message, :author, :timestamp]
end

defmodule IexCode.Tools.Git.LogEntry do
  @moduledoc """
  Structured commit log history entry.
  """
  @type t :: %__MODULE__{
          hash: String.t(),
          short_hash: String.t(),
          author: String.t(),
          email: String.t(),
          date: String.t(),
          subject: String.t(),
          body: String.t()
        }
  defstruct [:hash, :short_hash, :author, :email, :date, :subject, :body]
end

defmodule IexCode.Tools.Git.Status do
  @moduledoc """
  Parses raw porcelain v1 output into a structured StatusResult.
  """

  alias IexCode.Tools.Git.StatusResult

  @doc """
  Parses `git status --porcelain=v1 -b -uall` output.
  """
  @spec parse(String.t()) :: StatusResult.t()
  def parse(output) when is_binary(output) do
    lines =
      output
      |> String.split(~r/\r?\n/)
      |> Enum.reject(&(String.trim(&1) == ""))

    initial_acc = %StatusResult{
      branch: "main",
      upstream: nil,
      ahead: 0,
      behind: 0,
      initial?: false,
      staged: [],
      unstaged: [],
      untracked: [],
      conflicted: [],
      clean?: true
    }

    result = Enum.reduce(lines, initial_acc, &process_line/2)

    clean? =
      result.staged == [] and
        result.unstaged == [] and
        result.untracked == [] and
        result.conflicted == []

    %{result | clean?: clean?}
  end

  defp process_line("## " <> branch_line, acc) do
    parse_branch_line(branch_line, acc)
  end

  defp process_line("??" <> path, acc) do
    clean_path = String.trim(path)
    %{acc | untracked: acc.untracked ++ [clean_path]}
  end

  defp process_line(<<x::binary-size(1), y::binary-size(1), " ", path_rest::binary>>, acc) do
    path_trim = String.trim(path_rest)

    # Check for conflict status
    if {x, y} in [
         {"U", "U"},
         {"A", "A"},
         {"D", "D"},
         {"U", "D"},
         {"D", "U"},
         {"A", "U"},
         {"U", "A"}
       ] do
      conflict_entry = %{path: path_trim, status: :conflict, code: x <> y}
      %{acc | conflicted: acc.conflicted ++ [conflict_entry]}
    else
      # Check staged change (index X)
      staged_entry = parse_staged_char(x, path_trim)
      acc1 = if staged_entry, do: %{acc | staged: acc.staged ++ [staged_entry]}, else: acc

      # Check unstaged change (worktree Y)
      unstaged_entry = parse_unstaged_char(y, path_trim)
      if unstaged_entry, do: %{acc1 | unstaged: acc1.unstaged ++ [unstaged_entry]}, else: acc1
    end
  end

  defp process_line(_other, acc), do: acc

  # --- Branch Line Parsing ---

  defp parse_branch_line(line, acc) do
    cond do
      String.starts_with?(line, "No commits yet on ") ->
        branch = String.replace_prefix(line, "No commits yet on ", "")
        %{acc | branch: branch, initial?: true}

      String.starts_with?(line, "Initial commit on ") ->
        branch = String.replace_prefix(line, "Initial commit on ", "")
        %{acc | branch: branch, initial?: true}

      String.starts_with?(line, "HEAD (no branch)") ->
        %{acc | branch: "HEAD (detached)"}

      true ->
        # Example: main...origin/main [ahead 1, behind 2]
        # or main
        case Regex.run(~r/^([^ \.]+)(?:\.\.\.([^ \[]+))?(?:\s+\[(.*)\])?/, line) do
          [_, branch, upstream, tracking] ->
            {ahead, behind} = parse_ahead_behind(tracking)

            %{
              acc
              | branch: branch,
                upstream: if(upstream != "", do: upstream, else: nil),
                ahead: ahead,
                behind: behind
            }

          [_, branch, upstream] ->
            %{acc | branch: branch, upstream: if(upstream != "", do: upstream, else: nil)}

          [_, branch] ->
            %{acc | branch: branch}

          _ ->
            %{acc | branch: line}
        end
    end
  end

  defp parse_ahead_behind(nil), do: {0, 0}
  defp parse_ahead_behind(""), do: {0, 0}

  defp parse_ahead_behind(str) do
    ahead =
      case Regex.run(~r/ahead\s+(\d+)/, str) do
        [_, a] -> String.to_integer(a)
        _ -> 0
      end

    behind =
      case Regex.run(~r/behind\s+(\d+)/, str) do
        [_, b] -> String.to_integer(b)
        _ -> 0
      end

    {ahead, behind}
  end

  defp parse_staged_char("M", path), do: %{path: path, status: :modified, old_path: nil}
  defp parse_staged_char("A", path), do: %{path: path, status: :added, old_path: nil}
  defp parse_staged_char("D", path), do: %{path: path, status: :deleted, old_path: nil}
  defp parse_staged_char("C", path), do: %{path: path, status: :copied, old_path: nil}

  defp parse_staged_char("R", path) do
    case String.split(path, " -> ") do
      [old_p, new_p] -> %{path: new_p, status: :renamed, old_path: old_p}
      _ -> %{path: path, status: :renamed, old_path: nil}
    end
  end

  defp parse_staged_char(_other, _path), do: nil

  defp parse_unstaged_char("M", path), do: %{path: path, status: :modified}
  defp parse_unstaged_char("D", path), do: %{path: path, status: :deleted}
  defp parse_unstaged_char(_other, _path), do: nil
end

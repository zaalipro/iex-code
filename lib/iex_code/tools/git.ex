defmodule IexCode.Tools.Git do
  @moduledoc """
  Git porcelain and plumbing integration engine.
  Provides structured status inspection, diff extraction, staging, committing,
  and conventional semantic commit message generation.
  """

  alias IexCode.Tools.Git.{Status, StatusResult, CommitResult, LogEntry, CommitGenerator}

  @doc """
  Returns the structured Git status of the repository at `repo_dir`.
  """
  @spec status(Path.t()) :: {:ok, StatusResult.t()} | {:error, term()}
  def status(repo_dir \\ ".") do
    case run_git(repo_dir, ["status", "--porcelain=v1", "-b", "-uall"]) do
      {:ok, output} ->
        {:ok, Status.parse(output)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the diff string.

  ## Options
  - `:staged` - Boolean, returns staged diff (`--cached`)
  - `:paths` - List of file paths to filter
  - `:commit` - Revision/commit range (e.g. "HEAD~1")
  - `:unified` - Context line count (default: 3)
  - `:stat` - Boolean, returns diffstat summary
  """
  @spec diff(Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def diff(repo_dir \\ ".", opts \\ []) do
    args = ["diff"]

    args =
      if Keyword.get(opts, :staged, false) do
        args ++ ["--cached"]
      else
        args
      end

    args =
      if Keyword.get(opts, :stat, false) do
        args ++ ["--stat"]
      else
        args
      end

    args =
      case Keyword.get(opts, :unified) do
        n when is_integer(n) -> args ++ ["-U#{n}"]
        _ -> args
      end

    args =
      case Keyword.get(opts, :commit) do
        c when is_binary(c) and c != "" -> args ++ [c]
        _ -> args
      end

    paths = Keyword.get(opts, :paths, [])

    args =
      if paths != [] do
        args ++ ["--"] ++ List.wrap(paths)
      else
        args
      end

    run_git(repo_dir, args)
  end

  @doc """
  Stages one or more files in the repository (`git add`).
  Accepts `(files, repo_dir)` or `(repo_dir, files)`.
  """
  def stage(arg1, arg2 \\ ".")

  def stage(files, repo_dir)
      when is_binary(repo_dir) and (is_list(files) or is_binary(files) or files == :all) do
    do_stage(repo_dir, files)
  end

  def stage(repo_dir, files)
      when is_binary(repo_dir) and (is_list(files) or is_binary(files) or files == :all) do
    do_stage(repo_dir, files)
  end

  defp do_stage(repo_dir, :all) do
    case run_git(repo_dir, ["add", "-A"]) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp do_stage(repo_dir, ".") do
    do_stage(repo_dir, :all)
  end

  defp do_stage(repo_dir, files) when is_list(files) do
    case run_git(repo_dir, ["add", "--"] ++ files) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp do_stage(repo_dir, file) when is_binary(file) do
    do_stage(repo_dir, [file])
  end

  @doc """
  Unstages one or more files from the index (`git restore --staged` or `git reset HEAD`).
  Accepts `(files, repo_dir)` or `(repo_dir, files)`.
  """
  def unstage(arg1, arg2 \\ ".")

  def unstage(files, repo_dir)
      when is_binary(repo_dir) and (is_list(files) or is_binary(files) or files == :all) do
    do_unstage(repo_dir, files)
  end

  def unstage(repo_dir, files)
      when is_binary(repo_dir) and (is_list(files) or is_binary(files) or files == :all) do
    do_unstage(repo_dir, files)
  end

  defp do_unstage(repo_dir, :all) do
    case run_git(repo_dir, ["restore", "--staged", "."]) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        # Fallback for older git or empty initial repository
        case run_git(repo_dir, ["reset", "HEAD"]) do
          {:ok, _} -> :ok
          err -> err
        end
    end
  end

  defp do_unstage(repo_dir, ".") do
    do_unstage(repo_dir, :all)
  end

  defp do_unstage(repo_dir, files) when is_list(files) do
    case run_git(repo_dir, ["restore", "--staged", "--"] ++ files) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        case run_git(repo_dir, ["reset", "HEAD", "--"] ++ files) do
          {:ok, _} -> :ok
          err -> err
        end
    end
  end

  defp do_unstage(repo_dir, file) when is_binary(file) do
    do_unstage(repo_dir, [file])
  end

  @doc """
  Creates a commit with the specified message.
  Accepts `(message, repo_dir, opts)` or `(repo_dir, message, opts)`.
  """
  def commit(arg1, arg2 \\ ".", opts \\ [])

  def commit(message, repo_dir, opts)
      when is_binary(message) and is_binary(repo_dir) and is_list(opts) do
    do_commit(repo_dir, message, opts)
  end

  def commit(repo_dir, message, opts)
      when is_binary(repo_dir) and is_binary(message) and is_list(opts) do
    do_commit(repo_dir, message, opts)
  end

  defp do_commit(repo_dir, message, opts) do
    allow_empty = Keyword.get(opts, :allow_empty, false)

    with {:ok, status_res} <- status(repo_dir) do
      if not allow_empty and status_res.staged == [] do
        {:error, :nothing_staged}
      else
        author_args = [
          "-c",
          "user.name=IexCode Agent",
          "-c",
          "user.email=agent@iexcode.local"
        ]

        commit_args =
          if allow_empty do
            author_args ++ ["commit", "--allow-empty", "-m", message]
          else
            author_args ++ ["commit", "-m", message]
          end

        case run_git(repo_dir, commit_args) do
          {:ok, _commit_output} ->
            {:ok, full_hash} = run_git(repo_dir, ["rev-parse", "HEAD"])
            {:ok, short_hash} = run_git(repo_dir, ["rev-parse", "--short", "HEAD"])

            result = %CommitResult{
              commit_hash: String.trim(full_hash),
              short_hash: String.trim(short_hash),
              message: message,
              author: "IexCode Agent <agent@iexcode.local>",
              timestamp: DateTime.utc_now()
            }

            {:ok, result}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  @doc """
  Returns recent commit history as a structured list of LogEntry items.
  """
  @spec log(Path.t(), keyword()) :: {:ok, [LogEntry.t()]} | {:error, term()}
  def log(repo_dir \\ ".", opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    delimiter = "---COMMIT-DELIMITER---"
    format = "#{delimiter}%n%H%n%h%n%an%n%ae%n%ad%n%s%n%b"

    case run_git(repo_dir, ["log", "-n", to_string(limit), "--format=#{format}"]) do
      {:ok, output} ->
        entries =
          output
          |> String.split(delimiter)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(fn chunk ->
            case String.split(chunk, ~r/\r?\n/, parts: 7) do
              [hash, short_h, author, email, date, subject | rest] ->
                body = Enum.join(rest, "\n") |> String.trim()

                %LogEntry{
                  hash: hash,
                  short_hash: short_h,
                  author: author,
                  email: email,
                  date: date,
                  subject: subject,
                  body: body
                }

              _ ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns current active branch name.
  """
  @spec current_branch(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def current_branch(repo_dir \\ ".") do
    case run_git(repo_dir, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, branch} -> {:ok, String.trim(branch)}
      err -> err
    end
  end

  @doc """
  Generates a Conventional Semantic Commit message from staged changes or a diff string.
  """
  @spec generate_commit_message(Path.t() | String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_commit_message(diff_or_repo \\ ".", opts \\ [])

  def generate_commit_message(diff_str, _opts)
      when is_binary(diff_str) and
             (binary_part(diff_str, 0, min(10, byte_size(diff_str))) == "diff --git" or
                binary_part(diff_str, 0, min(6, byte_size(diff_str))) == "--- a/") do
    CommitGenerator.generate(diff_str, [])
  end

  def generate_commit_message(repo_dir, _opts) when is_binary(repo_dir) do
    with {:ok, status_res} <- status(repo_dir),
         {:ok, staged_diff} <- diff(repo_dir, staged: true) do
      staged_paths = Enum.map(status_res.staged, & &1.path)

      diff_text =
        if staged_diff != "" do
          staged_diff
        else
          case diff(repo_dir, []) do
            {:ok, working_diff} -> working_diff
            _ -> ""
          end
        end

      CommitGenerator.generate(diff_text, staged_paths ++ status_res.untracked)
    end
  end

  @doc """
  Applies a patch string to the repository using `git apply`.

  ## Options
  - `:cached` - Boolean, applies patch to index (staged) only
  - `:reverse` - Boolean, applies the patch in reverse (discards changes)
  - `:index` - Boolean, applies patch to both index and working tree
  - `:3way` - Boolean, attempts 3-way merge if patch does not apply cleanly
  - `:whitespace` - Option for git apply whitespace handling (e.g. "nowarn", "fix")
  - `:check` - Boolean, checks if patch can be applied without touching index/worktree
  """
  @spec apply_patch(Path.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def apply_patch(repo_dir, patch_content, opts \\ []) when is_binary(patch_content) do
    args = ["apply"]

    args = if Keyword.get(opts, :cached, false), do: args ++ ["--cached"], else: args
    args = if Keyword.get(opts, :reverse, false), do: args ++ ["--reverse"], else: args
    args = if Keyword.get(opts, :index, false), do: args ++ ["--index"], else: args
    args = if Keyword.get(opts, :check, false), do: args ++ ["--check"], else: args

    args =
      if Keyword.get(opts, :three_way, false) or Keyword.get(opts, :"3way", false),
        do: args ++ ["--3way"],
        else: args

    args =
      case Keyword.get(opts, :whitespace) do
        ws when is_binary(ws) -> args ++ ["--whitespace=#{ws}"]
        _ -> args
      end

    temp_file =
      Path.join(
        System.tmp_dir!(),
        "git_patch_#{System.system_time(:microsecond)}_#{:erlang.unique_integer([:positive])}.patch"
      )

    try do
      File.write!(temp_file, patch_content)
      run_git(repo_dir, args ++ [temp_file])
    after
      File.rm(temp_file)
    end
  end

  @doc """
  Restores/discards changes to specified files in working tree or staged index.
  """
  @spec restore_file(Path.t(), Path.t() | [Path.t()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def restore_file(repo_dir, files, opts \\ []) do
    file_list = List.wrap(files)
    staged = Keyword.get(opts, :staged, true)
    worktree = Keyword.get(opts, :worktree, true)

    # First unstage if staged
    if staged do
      unstage(repo_dir, file_list)
    end

    # Then restore worktree
    if worktree do
      case run_git(repo_dir, ["restore", "--"] ++ file_list) do
        {:ok, _} = res ->
          res

        {:error, _} ->
          # Fallback for older git
          run_git(repo_dir, ["checkout", "HEAD", "--"] ++ file_list)
      end
    else
      {:ok, "unstaged"}
    end
  end

  # --- Internal Git Invocation ---

  def run_git(repo_dir, args) do
    full_path = Path.expand(repo_dir)

    try do
      case System.cmd("git", args, cd: full_path, stderr_to_stdout: true) do
        {output, 0} ->
          {:ok, output}

        {output, exit_code} ->
          if String.contains?(output, "not a git repository") do
            {:error, :not_a_git_repo}
          else
            {:error, {:git_error, exit_code, String.trim(output)}}
          end
      end
    rescue
      ex ->
        {:error, ex}
    end
  end
end

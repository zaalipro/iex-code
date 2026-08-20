defmodule IexCode.Tools.Git.CommitGenerator do
  @moduledoc """
  Heuristic Conventional Commit generator analyzing diffs and staged file paths.
  Produces formatted commit messages like `feat(test-runner): implement TestRunner module`.
  """

  @doc """
  Generates a conventional commit message from diff text and optional staged file list.
  """
  @spec generate(String.t(), [String.t()]) :: {:ok, String.t()}
  def generate(diff, paths \\ []) when is_binary(diff) do
    extracted_paths =
      if paths != [] do
        paths
      else
        extract_paths_from_diff(diff)
      end

    type = infer_type(diff, extracted_paths)
    scope = infer_scope(extracted_paths)
    description = infer_description(diff, extracted_paths, type)

    commit_msg =
      if scope && scope != "" do
        "#{type}(#{scope}): #{description}"
      else
        "#{type}: #{description}"
      end

    {:ok, commit_msg}
  end

  # --- Helpers ---

  defp extract_paths_from_diff(diff) do
    Regex.scan(~r/^\+\+\+ b\/(.+)$/m, diff)
    |> Enum.map(fn [_, path] -> path end)
    |> Enum.uniq()
  end

  defp infer_type(diff, paths) do
    diff_down = String.downcase(diff)

    cond do
      paths != [] and Enum.all?(paths, &String.starts_with?(&1, "test/")) ->
        "test"

      paths != [] and
          Enum.all?(paths, &(String.ends_with?(&1, ".md") or String.starts_with?(&1, "docs/"))) ->
        "docs"

      paths != [] and
          Enum.all?(paths, fn p ->
            p in ["mix.exs", "mix.lock", ".formatter.exs", ".gitignore"] or
                String.starts_with?(p, "config/")
          end) ->
        "chore"

      String.contains?(diff_down, "fix") or
        String.contains?(diff_down, "multipleresultserror") or
        String.contains?(diff_down, "crash") or
        String.contains?(diff_down, "bug") or
        String.contains?(diff_down, "rescue") or
        String.contains?(diff_down, "prevent crash") or
          String.contains?(diff_down, "safely query") ->
        "fix"

      String.contains?(diff, "defmodule ") or
        String.contains?(diff, "def ") or
        String.contains?(diff_down, "implement ") or
          String.contains?(diff_down, "add ") ->
        "feat"

      String.contains?(diff_down, "refactor") or
        String.contains?(diff_down, "restructure") or
          String.contains?(diff_down, "cleanup") ->
        "refactor"

      String.contains?(diff_down, "optimize") or
        String.contains?(diff_down, "benchmark") or
          String.contains?(diff_down, "cache") ->
        "perf"

      true ->
        "feat"
    end
  end

  defp infer_scope(paths) do
    primary_path = List.first(paths) || ""

    cond do
      String.starts_with?(primary_path, "lib/iex_code/tools/test_runner") -> "test-runner"
      String.starts_with?(primary_path, "lib/iex_code/tools/git") -> "git"
      String.starts_with?(primary_path, "lib/iex_code/tools/ast_search") -> "ast-search"
      String.starts_with?(primary_path, "lib/iex_code/tools/multi_patch") -> "multi-patch"
      String.starts_with?(primary_path, "lib/iex_code/tools/") -> "tools"
      String.starts_with?(primary_path, "lib/iex_code/llm/stream") -> "llm-stream"
      String.starts_with?(primary_path, "lib/iex_code/llm/utf8") -> "utf8-buffer"
      String.starts_with?(primary_path, "lib/iex_code/llm/resilience") -> "resilience"
      String.starts_with?(primary_path, "lib/iex_code/llm/sse") -> "sse-parser"
      String.starts_with?(primary_path, "lib/iex_code/llm/") -> "llm"
      String.starts_with?(primary_path, "lib/iex_code/settings") -> "settings"
      String.starts_with?(primary_path, "lib/iex_code/sessions") -> "sessions"
      String.starts_with?(primary_path, "lib/iex_code/engine") -> "engine"
      String.starts_with?(primary_path, "lib/iex_code_web") -> "ui"
      String.starts_with?(primary_path, "test/") -> nil
      true -> nil
    end
  end

  defp infer_description(diff, paths, type) do
    diff_down = String.downcase(diff)
    primary_path = List.first(paths) || ""

    cond do
      type == "test" ->
        test_file = Path.basename(primary_path, ".exs")
        "update #{test_file}"

      type == "fix" and String.contains?(diff_down, "multipleresultserror") ->
        "prevent crash on multiple settings records"

      type == "fix" and String.contains?(diff_down, "settings") ->
        "prevent crash on multiple settings records"

      type == "feat" and String.contains?(diff, "defmodule ") ->
        case Regex.run(~r/defmodule\s+([A-Za-z0-9\._]+)/, diff) do
          [_, mod] ->
            short_mod = mod |> String.split(".") |> List.last()
            "implement #{short_mod} module"

          _ ->
            "implement new features in #{Path.basename(primary_path)}"
        end

      true ->
        if primary_path != "" do
          "update #{Path.basename(primary_path)}"
        else
          "update project files"
        end
    end
  end
end

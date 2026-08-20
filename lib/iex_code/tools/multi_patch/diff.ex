defmodule IexCode.Tools.MultiPatch.Diff do
  @moduledoc """
  Unified diff generator for text changes across files.
  """

  @doc """
  Generates a unified diff string comparing `orig` to `new` for `path`.
  """
  @spec unified_diff(String.t(), String.t(), Path.t()) :: String.t()
  def unified_diff(orig, new, path \\ "file") do
    orig_lines = String.split(orig || "", ~r/\r?\n/)
    new_lines = String.split(new || "", ~r/\r?\n/)

    if orig_lines == new_lines do
      ""
    else
      header = "--- a/#{path}\n+++ b/#{path}\n"
      diff_body = generate_hunks(orig_lines, new_lines)
      header <> diff_body
    end
  end

  defp generate_hunks(orig_lines, new_lines) do
    # Simple line-by-line diff generation
    changes = List.myers_difference(orig_lines, new_lines)

    lines =
      Enum.flat_map(changes, fn
        {:eq, list} ->
          Enum.map(list, fn l -> " " <> l end)

        {:del, list} ->
          Enum.map(list, fn l -> "-" <> l end)

        {:ins, list} ->
          Enum.map(list, fn l -> "+" <> l end)
      end)

    orig_count = length(orig_lines)
    new_count = length(new_lines)
    hunk_header = "@@ -1,#{orig_count} +1,#{new_count} @@\n"
    hunk_header <> Enum.join(lines, "\n") <> "\n"
  end
end

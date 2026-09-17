defmodule IexCode.MCP.Skills do
  @moduledoc """
  Discovers `SKILL.md` skill files for agents.

  Searches each directory in `dirs` for `*/SKILL.md` plus a bare
  `SKILL.md`, parsing the `name:`/`description:` frontmatter when present:

      ---
      name: review
      description: Review a diff for bugs.
      ---
      # Review
      ...

  Project skills live under `<project>/.iex/skills/`; user skills under
  `~/.config/iex-code/skills/`. Pass explicit dirs to load anywhere else.
  """

  @type skill :: %{name: String.t(), description: String.t(), body: String.t(), path: String.t()}

  @doc "Loads skills from `dirs` (later dirs win on name clashes)."
  @spec load([String.t()]) :: [skill()]
  def load(dirs) when is_list(dirs) do
    dirs
    |> Enum.flat_map(&dir_skills/1)
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.name)
    |> Enum.reverse()
    |> Enum.sort_by(& &1.name)
  end

  @doc "Default user-level skills directory."
  @spec user_dir() :: String.t()
  def user_dir, do: Path.join([System.user_home!(), ".config", "iex-code", "skills"])

  @doc "Default project-level skills directory for a project root."
  @spec project_dir(String.t()) :: String.t()
  def project_dir(root) when is_binary(root), do: Path.join([root, ".iex", "skills"])

  @doc "Renders loaded skills as a system-prompt section."
  @spec prompt_section([skill()]) :: String.t()
  def prompt_section([]), do: ""

  def prompt_section(skills) do
    entries =
      Enum.map_join(skills, "\n", fn skill ->
        "- #{skill.name}: #{skill.description} (#{skill.path})"
      end)

    "Available skills (read the SKILL.md before using one):\n#{entries}"
  end

  defp dir_skills(dir) when is_binary(dir) do
    bare = Path.join(dir, "SKILL.md")

    nested =
      case File.ls(dir) do
        {:ok, entries} ->
          entries
          |> Enum.map(&Path.join([dir, &1, "SKILL.md"]))
          |> Enum.filter(&File.regular?/1)

        {:error, _reason} ->
          []
      end

    [bare | nested]
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&parse_skill/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_skill(path) do
    with {:ok, contents} <- File.read(path) do
      {frontmatter, body} = split_frontmatter(contents)
      name = Map.get(frontmatter, "name") || fallback_name(path)
      description = Map.get(frontmatter, "description", "")

      %{name: name, description: description, body: body, path: path}
    else
      {:error, _reason} -> nil
    end
  end

  defp split_frontmatter("---\n" <> rest) do
    case String.split(rest, "\n---\n", parts: 2) do
      [raw, body] -> {parse_frontmatter_lines(raw), body}
      [_only] -> {%{}, "---\n" <> rest}
    end
  end

  defp split_frontmatter(contents), do: {%{}, contents}

  defp parse_frontmatter_lines(raw) do
    raw
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          key = String.trim(key)

          if key in ["name", "description"] do
            Map.put(acc, key, String.trim(value))
          else
            acc
          end

        _single ->
          acc
      end
    end)
  end

  defp fallback_name(path) do
    path |> Path.dirname() |> Path.basename()
  end
end

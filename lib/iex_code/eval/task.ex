defmodule IexCode.Eval.Task do
  @moduledoc """
  A single coding-eval task: prompt, fixture repo, and grading command.

  Tasks load from `*.eval.json` files (Jason, no extra deps):

      {
        "id": "fix-typo",
        "prompt": "Fix the typo in README.md",
        "repo": "fixtures/fix-typo",
        "test_cmd": ["./grade.sh"],
        "timeout_ms": 120000,
        "max_turns": 8
      }

  Each sample copies `repo` to a fresh tmp workdir, runs the agent loop
  with `prompt`, then grades with `test_cmd` (exit 0 passes).
  """

  @enforce_keys [:id, :prompt, :repo, :test_cmd]
  defstruct [:id, :prompt, :repo, :test_cmd, timeout_ms: 120_000, max_turns: 8]

  @type t :: %__MODULE__{
          id: String.t(),
          prompt: String.t(),
          repo: String.t(),
          test_cmd: [String.t()],
          timeout_ms: pos_integer(),
          max_turns: pos_integer()
        }

  @doc "Parses and validates a task from a decoded JSON map."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(params) when is_map(params) do
    with {:ok, id} <- required_string(params, "id"),
         {:ok, prompt} <- required_string(params, "prompt"),
         {:ok, repo} <- required_string(params, "repo"),
         {:ok, test_cmd} <- required_command(params),
         {:ok, timeout_ms} <- optional_pos_int(params, "timeout_ms", 120_000),
         {:ok, max_turns} <- optional_pos_int(params, "max_turns", 8) do
      {:ok,
       %__MODULE__{
         id: id,
         prompt: prompt,
         repo: repo,
         test_cmd: test_cmd,
         timeout_ms: timeout_ms,
         max_turns: max_turns
       }}
    end
  end

  def from_map(_params), do: {:error, :eval_task_must_be_an_object}

  @doc "Loads all `*.eval.json` tasks from a directory (sorted by id)."
  @spec load_dir(String.t()) :: {:ok, [t()]} | {:error, term()}
  def load_dir(dir) when is_binary(dir) do
    if File.dir?(dir) do
      tasks =
        dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".eval.json"))
        |> Enum.sort()
        |> Enum.map(&load_file(Path.join(dir, &1)))

      errors = for {:error, reason} <- tasks, do: reason

      case errors do
        [] -> {:ok, for({:ok, task} <- tasks, do: task) |> Enum.sort_by(& &1.id)}
        [first | _rest] -> {:error, first}
      end
    else
      {:error, {:eval_tasks_dir_missing, dir}}
    end
  end

  defp load_file(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents),
         {:ok, task} <- from_map(decoded) do
      {:ok, task}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:eval_task_json, path, error}}
      {:error, reason} -> {:error, {:eval_task_file, path, reason}}
    end
  end

  defp required_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, {:eval_task_field, key}}, else: {:ok, value}

      _missing ->
        {:error, {:eval_task_field, key}}
    end
  end

  defp required_command(params) do
    case Map.get(params, "test_cmd") do
      [cmd | _rest] = full when is_binary(cmd) ->
        if Enum.all?(full, &is_binary/1),
          do: {:ok, full},
          else: {:error, {:eval_task_field, "test_cmd"}}

      _missing ->
        {:error, {:eval_task_field, "test_cmd"}}
    end
  end

  defp optional_pos_int(params, key, default) do
    case Map.get(params, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _invalid -> {:error, {:eval_task_field, key}}
    end
  end
end

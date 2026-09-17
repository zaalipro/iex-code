defmodule Mix.Tasks.IexCode.Eval do
  @moduledoc """
  Runs coding-eval tasks against the agent loop and reports pass@k.

      mix iex_code.eval [TASKS_DIR] [--samples N] [--ks 1,3] [--max-turns N]

  Tasks are `*.eval.json` files (see `IexCode.Eval.Task`). Each sample gets a
  fresh workdir copy of the task fixture, one agent run, and one grade
  command (exit 0 passes). Prints per-task and aggregate pass rates.
  """

  use Mix.Task

  @shortdoc "Runs coding-eval tasks and reports pass@k"

  @switches [samples: :integer, ks: :string, max_turns: :integer, help: :boolean]

  @impl true
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {_opts, _args, [{invalid, _} | _]} ->
        fail("invalid option #{invalid}")

      {opts, args, []} ->
        if opts[:help], do: Mix.shell().info(@moduledoc), else: eval(args, opts)
    end
  end

  defp eval(args, opts) do
    Mix.Task.run("app.start")

    dir = List.first(args) || "eval/tasks"

    with {:ok, samples} <- pos_int(Keyword.get(opts, :samples, 1), "--samples"),
         {:ok, ks} <- parse_ks(Keyword.get(opts, :ks, "1")),
         {:ok, results} <-
           IexCode.Eval.Runner.run(dir,
             samples: samples,
             ks: ks,
             on_sample: fn task, sample ->
               Mix.shell().info("  sample #{task.id}##{sample.sample}: #{verdict(sample.passed)}")
             end
           ) do
      Mix.shell().info(IexCode.Eval.Runner.format_report(results))
    else
      {:error, reason} -> fail(inspect(reason))
    end
  end

  defp parse_ks(value) when is_binary(value) do
    parts = value |> String.split(",") |> Enum.map(&String.trim/1)

    if Enum.all?(parts, &(&1 =~ ~r/^\d+$/)) do
      ks = parts |> Enum.map(&String.to_integer/1) |> Enum.filter(&(&1 > 0)) |> Enum.uniq()

      if ks == [], do: {:error, :eval_bad_ks}, else: {:ok, ks}
    else
      {:error, :eval_bad_ks}
    end
  end

  defp parse_ks(_value), do: {:error, :eval_bad_ks}

  defp pos_int(value, _flag) when is_integer(value) and value > 0, do: {:ok, value}
  defp pos_int(_value, flag), do: {:error, {:eval_bad_option, flag}}

  defp verdict(true), do: "PASS"
  defp verdict(false), do: "FAIL"

  defp fail(message) do
    Mix.shell().error("mix iex_code.eval: #{message}")
    exit({:shutdown, 1})
  end
end

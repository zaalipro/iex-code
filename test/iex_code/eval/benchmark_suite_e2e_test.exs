defmodule IexCode.Eval.BenchmarkSuiteE2ETest do
  use IexCode.DataCase, async: false

  alias IexCode.Eval.{Runner, Task}

  defmodule ScriptedBenchmarkLLM do
    @moduledoc false

    def chat(messages, _system_prompt, _session, _on_chunk, _opts) do
      prompt =
        Enum.find_value(messages, "", fn
          %{role: "user", content: content} -> content
          %{"role" => "user", "content" => content} -> content
          _ -> nil
        end)

      tool_messages =
        Enum.filter(messages, fn msg ->
          (Map.get(msg, :role) || Map.get(msg, "role")) == "tool"
        end)

      assistant_turns =
        Enum.count(messages, fn msg ->
          (Map.get(msg, :role) || Map.get(msg, "role")) == "assistant"
        end)

      cond do
        assistant_turns == 0 ->
          {:ok, turn_one_inspect(prompt)}

        assistant_turns == 1 ->
          {:ok, turn_two_apply(prompt, tool_messages)}

        true ->
          {:ok,
           %{
             text: "Completed requested fix and verified changes.",
             tool_calls: [],
             usage: %{input_tokens: 50, output_tokens: 20, cost_cents: 1}
           }}
      end
    end

    defp turn_one_inspect(prompt) do
      calls =
        cond do
          String.contains?(prompt, "TYPO.md") ->
            [%{id: "read-typo", name: "read_file", args: %{"path" => "TYPO.md"}}]

          String.contains?(prompt, "lib/paginator.ex") ->
            [%{id: "read-paginator", name: "read_file", args: %{"path" => "lib/paginator.ex"}}]

          String.contains?(prompt, "Pricing.calculate_total") ->
            [
              %{id: "read-pricing", name: "read_file", args: %{"path" => "lib/pricing.ex"}},
              %{id: "read-checkout", name: "read_file", args: %{"path" => "lib/checkout.ex"}},
              %{id: "read-invoice", name: "read_file", args: %{"path" => "lib/invoice.ex"}}
            ]

          String.contains?(prompt, "lib/rate_limiter.ex") ->
            [
              %{
                id: "read-rate-limiter",
                name: "read_file",
                args: %{"path" => "lib/rate_limiter.ex"}
              }
            ]

          String.contains?(prompt, "lib/event_buffer.ex") ->
            [
              %{
                id: "read-event-buffer",
                name: "read_file",
                args: %{"path" => "lib/event_buffer.ex"}
              }
            ]

          String.contains?(prompt, "lib/slugifier.ex") ->
            [%{id: "read-slugifier", name: "read_file", args: %{"path" => "lib/slugifier.ex"}}]
        end

      %{
        text: "Inspecting target files first.",
        tool_calls: calls,
        usage: %{input_tokens: 80, output_tokens: 30, cost_cents: 1}
      }
    end

    defp turn_two_apply(prompt, tool_messages) do
      for msg <- tool_messages do
        content = Map.get(msg, :content) || Map.get(msg, "content") || ""

        if String.contains?(content, "File does not exist") do
          raise "Unexpected read_file error in scripted LLM: #{content}"
        end
      end

      calls =
        cond do
          String.contains?(prompt, "TYPO.md") ->
            [
              %{
                id: "patch-typo",
                name: "patch_file",
                args: %{
                  "path" => "TYPO.md",
                  "target_content" => "teh quick brown fox.",
                  "replacement_content" => "the quick brown fox."
                }
              }
            ]

          String.contains?(prompt, "lib/paginator.ex") ->
            [
              %{
                id: "patch-paginator",
                name: "patch_file",
                args: %{
                  "path" => "lib/paginator.ex",
                  "target_content" => """
                      total = length(items)
                      total_pages = div(total, per_page)
                      offset = page * per_page
                      entries = Enum.slice(items, offset, per_page)

                      %{
                        entries: entries,
                        page: page,
                        per_page: per_page,
                        total: total,
                        total_pages: total_pages,
                        has_prev?: page > 1,
                        has_next?: page <= total_pages
                      }
                  """,
                  "replacement_content" => """
                      total = length(items)
                      total_pages = max(1, div(total + per_page - 1, per_page))
                      offset = (page - 1) * per_page
                      entries = Enum.slice(items, offset, per_page)

                      %{
                        entries: entries,
                        page: page,
                        per_page: per_page,
                        total: total,
                        total_pages: total_pages,
                        has_prev?: page > 1,
                        has_next?: page < total_pages
                      }
                  """
                }
              }
            ]

          String.contains?(prompt, "Pricing.calculate_total") ->
            [
              %{
                id: "multi-patch-contract",
                name: "multi_patch",
                args: %{
                  "patches" => [
                    %{
                      "path" => "lib/pricing.ex",
                      "target_content" => """
                        @spec calculate_total([%{price_cents: integer(), qty: pos_integer()}]) :: integer()
                        def calculate_total(items) when is_list(items) do
                          Enum.reduce(items, 0, fn item, acc ->
                            acc + item.price_cents * item.qty
                          end)
                        end
                      """,
                      "replacement_content" => """
                        @spec calculate_total([%{price_cents: integer(), qty: pos_integer()}], keyword()) ::
                                integer()
                        def calculate_total(items, opts \\\\ []) when is_list(items) and is_list(opts) do
                          discount_cents = Keyword.get(opts, :discount_cents, 0)
                          tax_rate = Keyword.get(opts, :tax_rate, 0.0)

                          subtotal =
                            Enum.reduce(items, 0, fn item, acc ->
                              acc + item.price_cents * item.qty
                            end)

                          discounted = max(0, subtotal - discount_cents)
                          round(discounted * (1.0 + tax_rate))
                        end
                      """
                    },
                    %{
                      "path" => "lib/checkout.ex",
                      "target_content" => """
                          _discount = Map.get(cart, :discount_cents, 0)
                          _tax_rate = Map.get(cart, :tax_rate, 0.0)
                          total = Pricing.calculate_total(items)
                      """,
                      "replacement_content" => """
                          discount = Map.get(cart, :discount_cents, 0)
                          tax_rate = Map.get(cart, :tax_rate, 0.0)
                          total = Pricing.calculate_total(items, discount_cents: discount, tax_rate: tax_rate)
                      """
                    },
                    %{
                      "path" => "lib/invoice.ex",
                      "target_content" => """
                          _discount = Map.get(order, :discount_cents, 0)
                          _tax_rate = Map.get(order, :tax_rate, 0.0)
                          total = Pricing.calculate_total(items)
                      """,
                      "replacement_content" => """
                          discount = Map.get(order, :discount_cents, 0)
                          tax_rate = Map.get(order, :tax_rate, 0.0)
                          total = Pricing.calculate_total(items, discount_cents: discount, tax_rate: tax_rate)
                      """
                    }
                  ]
                }
              }
            ]

          String.contains?(prompt, "lib/rate_limiter.ex") ->
            [
              %{
                id: "patch-webhook-only",
                name: "patch_file",
                args: %{
                  "path" => "lib/rate_limiter.ex",
                  "target_content" => """
                    def allow_webhook?(count, limit) when is_integer(count) and is_integer(limit) and limit >= 0 do
                      cond do
                        count < 0 -> {:error, :invalid_count}
                        count >= limit -> {:deny, 0}
                        true -> {:allow, limit - count}
                      end
                    end
                  """,
                  "replacement_content" => """
                    def allow_webhook?(count, limit) when is_integer(count) and is_integer(limit) and limit >= 0 do
                      cond do
                        count < 0 -> {:error, :invalid_count}
                        count > limit -> {:deny, 0}
                        true -> {:allow, limit - count}
                      end
                    end
                  """
                }
              }
            ]

          String.contains?(prompt, "lib/event_buffer.ex") ->
            [
              %{
                id: "patch-event-buffer",
                name: "patch_file",
                args: %{
                  "path" => "lib/event_buffer.ex",
                  "target_content" => """
                    @impl true
                    def handle_cast({:push, event}, state) do
                      events = state.events ++ [event]
                      {:noreply, %{state | events: events}}
                    end

                    @impl true
                    def handle_call(:list, _from, state) do
                      {:reply, state.events, state}
                    end

                    @impl true
                    def handle_info(:clear, state) do
                      {:noreply, %{state | events: []}}
                    end
                  """,
                  "replacement_content" => """
                    @impl true
                    def handle_cast({:push, event}, state) do
                      events = (state.events ++ [event]) |> Enum.take(-state.max_size)
                      {:noreply, %{state | events: events}}
                    end

                    @impl true
                    def handle_call(:list, _from, state) do
                      {:reply, state.events, state}
                    end

                    @impl true
                    def handle_info(:clear, state) do
                      {:noreply, %{state | events: []}}
                    end

                    @impl true
                    def handle_info(_msg, state) do
                      {:noreply, state}
                    end
                  """
                }
              }
            ]

          String.contains?(prompt, "lib/slugifier.ex") ->
            [
              %{
                id: "write-slugifier",
                name: "write_file",
                args: %{
                  "path" => "lib/slugifier.ex",
                  "content" => """
                  defmodule Slugifier do
                    @moduledoc \"\"\"
                    URL slug normalization helper.
                    \"\"\"

                    @spec slugify(String.t()) :: String.t()
                    def slugify(input) when is_binary(input) do
                      input
                      |> String.downcase()
                      |> String.replace(~r/[^a-z0-9]+/, "-")
                      |> String.trim("-")
                    end
                  end
                  """
                }
              }
            ]
        end

      %{
        text: "Applying the scoped repair.",
        tool_calls: calls,
        usage: %{input_tokens: 120, output_tokens: 60, cost_cents: 2}
      }
    end
  end

  test "all 6 eval tasks load cleanly and start in a genuinely failing state before agent execution" do
    assert {:ok, tasks} = Task.load_dir("eval/tasks")
    assert length(tasks) == 6

    expected_ids = [
      "elixir-compile-repair",
      "elixir-genserver-bounded-state",
      "elixir-multi-file-contract",
      "elixir-pagination-boundary",
      "elixir-repeated-block-patch",
      "example-markdown-typo"
    ]

    assert Enum.map(tasks, & &1.id) == expected_ids

    for task <- tasks do
      fixture = Path.expand(task.repo, "eval/tasks")
      assert File.dir?(fixture)

      [cmd | args] = task.test_cmd
      {_output, exit_code} = System.cmd(cmd, args, cd: fixture, stderr_to_stdout: true)
      assert exit_code != 0, "Expected #{task.id} fixture to fail before agent repair"
    end
  end

  test "full benchmark suite passes 6/6 through real AgentLoop and real Tools and cleans up workdirs" do
    assert {:ok, results} =
             Runner.run("eval/tasks",
               samples: 1,
               ks: [1],
               llm: ScriptedBenchmarkLLM,
               tool_executor: IexCode.Tools
             )

    assert length(results.tasks) == 6

    for task <- results.tasks do
      assert [sample] = task.samples

      assert sample.passed,
             "Expected #{task.id} to pass, got loop=#{inspect(sample.loop)} grade=#{inspect(sample.grade)} error=#{inspect(Map.get(sample, :error))}"

      assert is_integer(sample.duration_ms) and sample.duration_ms >= 0
      assert sample.turns == 3
      assert sample.tool_calls >= 2
      assert sample.input_tokens > 0
      assert sample.output_tokens > 0
      assert sample.cost_cents > 0
      refute File.exists?(sample.workdir)
    end

    assert results.aggregate.samples == 6
    assert results.aggregate.passed == 6
    assert results.aggregate.pass_rate == 1.0
    assert results.aggregate.pass_at_k == %{1 => 1.0}

    assert results.by_category["bugfix"].pass_rate == 1.0
    assert results.by_category["refactor"].pass_rate == 1.0
    assert results.by_category["ambiguous_edit"].pass_rate == 1.0
    assert results.by_category["concurrency"].pass_rate == 1.0
    assert results.by_category["compile_repair"].pass_rate == 1.0
    assert results.by_category["general"].pass_rate == 1.0

    report = Runner.format_report(results)
    assert report =~ "eval: 6 task(s) x 1 sample(s)"
    assert report =~ "aggregate: 6/6 passed"

    decoded = results |> Runner.to_json_report() |> Jason.decode!()
    assert decoded["aggregate"]["passed"] == 6
    assert decoded["aggregate"]["pass_rate"] == 1.0
  end

  test "mix iex_code.eval prints help, handles filter/json flags, and rejects invalid options" do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    assert :ok == Mix.Tasks.IexCode.Eval.run(["--help"])
    assert_receive {:mix_shell, :info, [help_text]}
    assert help_text =~ "--only"
    assert help_text =~ "--category"
    assert help_text =~ "--tag"
    assert help_text =~ "--json-out"
    assert help_text =~ "--keep-workdir"

    json_out =
      Path.join(
        System.tmp_dir!(),
        "eval-cli-report-#{System.unique_integer([:positive])}/report.json"
      )

    on_exit(fn -> File.rm_rf(Path.dirname(json_out)) end)

    assert :ok ==
             Mix.Tasks.IexCode.Eval.run([
               "eval/tasks",
               "--only",
               "nonexistent-task",
               "--category",
               "bugfix",
               "--tag",
               "elixir",
               "--max-turns",
               "4",
               "--keep-workdir",
               "--json-out",
               json_out
             ])

    assert_receive {:mix_shell, :info, [report_text]}
    assert report_text =~ "eval: 0 task(s) x 1 sample(s)"
    assert File.exists?(json_out)
    decoded = json_out |> File.read!() |> Jason.decode!()
    assert decoded["tasks"] == []
    assert decoded["aggregate"]["samples"] == 0

    assert {:shutdown, 1} == catch_exit(Mix.Tasks.IexCode.Eval.run(["--unknown-flag"]))
    assert_receive {:mix_shell, :error, [error_text]}
    assert error_text =~ "invalid option --unknown-flag"

    assert {:shutdown, 1} == catch_exit(Mix.Tasks.IexCode.Eval.run(["--only", "  "]))
    assert_receive {:mix_shell, :error, [only_err]}
    assert only_err =~ "--only"
  end
end

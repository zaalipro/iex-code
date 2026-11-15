defmodule IexCode.Eval.Round2BenchmarkTasksTest do
  use IexCode.DataCase, async: false

  alias IexCode.Eval.{Runner, Task}

  defmodule ScriptedRound2LLM do
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
             text: "Completed Round 2 benchmark repair.",
             tool_calls: [],
             usage: %{input_tokens: 45, output_tokens: 18, cost_cents: 1}
           }}
      end
    end

    defp turn_one_inspect(prompt) do
      calls =
        cond do
          String.contains?(prompt, "lib/orders.ex") ->
            [
              %{id: "read-ledger", name: "read_file", args: %{"path" => "lib/ledger.ex"}},
              %{id: "read-orders", name: "read_file", args: %{"path" => "lib/orders.ex"}}
            ]

          String.contains?(prompt, "lib/job_coordinator.ex") ->
            [
              %{
                id: "read-coordinator",
                name: "read_file",
                args: %{"path" => "lib/job_coordinator.ex"}
              }
            ]
        end

      %{
        text: "Inspecting target files first.",
        tool_calls: calls,
        usage: %{input_tokens: 75, output_tokens: 25, cost_cents: 1}
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
          String.contains?(prompt, "lib/orders.ex") ->
            [
              %{
                id: "patch-orders",
                name: "patch_file",
                args: %{
                  "path" => "lib/orders.ex",
                  "target_content" => """
                      with {:ok, account} <- fetch_account(state, account_id) do
                        total_cents = price * qty

                        if account.balance_cents >= total_cents do
                          updated_account = %{account | reserved_cents: total_cents}

                          order = %{
                            id: order_id,
                            account_id: account_id,
                            amount_cents: total_cents,
                            status: :pending
                          }

                          new_state = %{
                            state
                            | accounts: Map.put(state.accounts, account_id, updated_account),
                              orders: Map.put(state.orders, order_id, order)
                          }

                          {:ok, order, new_state}
                        else
                          {:error, :insufficient_funds}
                        end
                      end
                    end

                    def place_order(_state, _account_id, _attrs), do: {:error, :invalid_order}

                    @spec cancel_order(state(), String.t()) ::
                            {:ok, order(), state()}
                            | {:error, :order_not_found | :already_cancelled | :account_not_found}
                    def cancel_order(state, order_id) do
                      case Map.fetch(state.orders, order_id) do
                        {:ok, order} ->
                          with {:ok, account} <- fetch_account(state, order.account_id) do
                            updated_account = %{
                              account
                              | reserved_cents: account.reserved_cents - order.amount_cents
                            }

                            cancelled = %{order | status: :cancelled}

                            new_state = %{
                              state
                              | accounts: Map.put(state.accounts, order.account_id, updated_account),
                                orders: Map.put(state.orders, order_id, cancelled)
                            }

                            {:ok, cancelled, new_state}
                          end

                        :error ->
                          {:error, :order_not_found}
                      end
                    end

                    @spec list_orders(state(), String.t(), keyword()) :: [order()]
                    def list_orders(state, account_id, opts \\\\ []) do
                      status = Keyword.get(opts, :status)

                      state.orders
                      |> Map.values()
                      |> Enum.filter(fn order ->
                        order.account_id == account_id and (is_nil(status) or order.status == status)
                      end)
                      |> Enum.sort_by(& &1.id, :desc)
                    end
                  """,
                  "replacement_content" => """
                      if Map.has_key?(state.orders, order_id) do
                        {:error, :duplicate_order}
                      else
                        with {:ok, account} <- fetch_account(state, account_id),
                             total_cents = price * qty,
                             {:ok, updated_account} <- Ledger.reserve(account, total_cents) do
                          order = %{
                            id: order_id,
                            account_id: account_id,
                            amount_cents: total_cents,
                            status: :pending
                          }

                          new_state = %{
                            state
                            | accounts: Map.put(state.accounts, account_id, updated_account),
                              orders: Map.put(state.orders, order_id, order)
                          }

                          {:ok, order, new_state}
                        end
                      end
                    end

                    def place_order(_state, _account_id, _attrs), do: {:error, :invalid_order}

                    @spec cancel_order(state(), String.t()) ::
                            {:ok, order(), state()}
                            | {:error, :order_not_found | :already_cancelled | :account_not_found}
                    def cancel_order(state, order_id) do
                      case Map.fetch(state.orders, order_id) do
                        {:ok, %{status: :cancelled}} ->
                          {:error, :already_cancelled}

                        {:ok, order} ->
                          with {:ok, account} <- fetch_account(state, order.account_id) do
                            updated_account = Ledger.release(account, order.amount_cents)
                            cancelled = %{order | status: :cancelled}

                            new_state = %{
                              state
                              | accounts: Map.put(state.accounts, order.account_id, updated_account),
                                orders: Map.put(state.orders, order_id, cancelled)
                            }

                            {:ok, cancelled, new_state}
                          end

                        :error ->
                          {:error, :order_not_found}
                      end
                    end

                    @spec list_orders(state(), String.t(), keyword()) :: [order()]
                    def list_orders(state, account_id, opts \\\\ []) do
                      status = Keyword.get(opts, :status)

                      state.orders
                      |> Map.values()
                      |> Enum.filter(fn order ->
                        order.account_id == account_id and (is_nil(status) or order.status == status)
                      end)
                      |> Enum.sort_by(& &1.id, :asc)
                    end
                  """
                }
              }
            ]

          String.contains?(prompt, "lib/job_coordinator.ex") ->
            [
              %{
                id: "patch-job-coordinator",
                name: "patch_file",
                args: %{
                  "path" => "lib/job_coordinator.ex",
                  "target_content" => """
                      # BUG 1: unmonitored spawn; worker crashes are never observed so caller hangs
                      worker_pid =
                        spawn(fn ->
                          result = fun.()
                          send(parent, {:job_done, job_id, result})
                        end)

                      timer_ref = Process.send_after(self(), {:job_timeout, job_id}, timeout_ms)

                      job = %{
                        from: from,
                        worker_pid: worker_pid,
                        timer_ref: timer_ref
                      }

                      new_state = %{
                        state
                        | next_id: job_id + 1,
                          jobs: Map.put(state.jobs, job_id, job)
                      }

                      {:noreply, new_state}
                    end

                    def handle_call(:active_count, _from, state) do
                      {:reply, map_size(state.jobs), state}
                    end

                    def handle_call(:stats, _from, state) do
                      {:reply, state.stats, state}
                    end

                    @impl true
                    def handle_info({:job_done, job_id, result}, state) do
                      case Map.pop(state.jobs, job_id) do
                        {nil, _jobs} ->
                          {:noreply, state}

                        {job, remaining_jobs} ->
                          Process.cancel_timer(job.timer_ref)
                          GenServer.reply(job.from, {:ok, result})
                          stats = Map.update!(state.stats, :completed, &(&1 + 1))
                          {:noreply, %{state | jobs: remaining_jobs, stats: stats}}
                      end
                    end

                    def handle_info({:job_timeout, job_id}, state) do
                      case Map.get(state.jobs, job_id) do
                        nil ->
                          {:noreply, state}

                        job ->
                          # BUG 2: replies timeout without killing worker_pid or removing job from state.jobs
                          GenServer.reply(job.from, {:error, :timeout})
                          stats = Map.update!(state.stats, :timed_out, &(&1 + 1))
                          {:noreply, %{state | stats: stats}}
                      end
                    end
                  """,
                  "replacement_content" => """
                      worker_pid =
                        spawn(fn ->
                          result = fun.()
                          send(parent, {:job_done, job_id, result})
                        end)

                      monitor_ref = Process.monitor(worker_pid)
                      timer_ref = Process.send_after(self(), {:job_timeout, job_id}, timeout_ms)

                      job = %{
                        from: from,
                        worker_pid: worker_pid,
                        monitor_ref: monitor_ref,
                        timer_ref: timer_ref
                      }

                      new_state = %{
                        state
                        | next_id: job_id + 1,
                          jobs: Map.put(state.jobs, job_id, job)
                      }

                      {:noreply, new_state}
                    end

                    def handle_call(:active_count, _from, state) do
                      {:reply, map_size(state.jobs), state}
                    end

                    def handle_call(:stats, _from, state) do
                      {:reply, state.stats, state}
                    end

                    @impl true
                    def handle_info({:job_done, job_id, result}, state) do
                      case Map.pop(state.jobs, job_id) do
                        {nil, _jobs} ->
                          {:noreply, state}

                        {job, remaining_jobs} ->
                          Process.cancel_timer(job.timer_ref)
                          Process.demonitor(job.monitor_ref, [:flush])
                          GenServer.reply(job.from, {:ok, result})
                          stats = Map.update!(state.stats, :completed, &(&1 + 1))
                          {:noreply, %{state | jobs: remaining_jobs, stats: stats}}
                      end
                    end

                    def handle_info({:job_timeout, job_id}, state) do
                      case Map.pop(state.jobs, job_id) do
                        {nil, _jobs} ->
                          {:noreply, state}

                        {job, remaining_jobs} ->
                          Process.demonitor(job.monitor_ref, [:flush])

                          if Process.alive?(job.worker_pid) do
                            Process.exit(job.worker_pid, :kill)
                          end

                          GenServer.reply(job.from, {:error, :timeout})
                          stats = Map.update!(state.stats, :timed_out, &(&1 + 1))
                          {:noreply, %{state | jobs: remaining_jobs, stats: stats}}
                      end
                    end

                    def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
                      case Enum.find(state.jobs, fn {_id, job} -> job.monitor_ref == ref end) do
                        nil ->
                          {:noreply, state}

                        {job_id, job} ->
                          Process.cancel_timer(job.timer_ref)
                          remaining_jobs = Map.delete(state.jobs, job_id)

                          receive do
                            {:job_done, ^job_id, result} ->
                              GenServer.reply(job.from, {:ok, result})
                              stats = Map.update!(state.stats, :completed, &(&1 + 1))
                              {:noreply, %{state | jobs: remaining_jobs, stats: stats}}
                          after
                            0 ->
                              GenServer.reply(job.from, {:error, {:worker_exit, reason}})
                              stats = Map.update!(state.stats, :failed, &(&1 + 1))
                              {:noreply, %{state | jobs: remaining_jobs, stats: stats}}
                          end
                      end
                    end
                  """
                }
              }
            ]
        end

      %{
        text: "Applying Round 2 repair.",
        tool_calls: calls,
        usage: %{input_tokens: 120, output_tokens: 60, cost_cents: 2}
      }
    end
  end

  test "Round 2 eval tasks #7-#8 load cleanly and fail pre-repair" do
    assert {:ok, all_tasks} = Task.load_dir("eval/tasks")
    assert length(all_tasks) == 10

    round2_ids = ["elixir-context-bugfix", "elixir-otp-timeout-leak"]
    tasks = Enum.filter(all_tasks, &(&1.id in round2_ids))
    assert Enum.map(tasks, & &1.id) == round2_ids

    context_task = Enum.find(tasks, &(&1.id == "elixir-context-bugfix"))
    assert context_task.category == "bugfix"
    assert context_task.difficulty == "medium"
    assert "context" in context_task.tags

    otp_task = Enum.find(tasks, &(&1.id == "elixir-otp-timeout-leak"))
    assert otp_task.category == "concurrency"
    assert otp_task.difficulty == "hard"
    assert "otp" in otp_task.tags

    for task <- tasks do
      fixture = Path.expand(task.repo, "eval/tasks")
      assert File.dir?(fixture)

      [cmd | args] = task.test_cmd
      {_output, exit_code} = System.cmd(cmd, args, cd: fixture, stderr_to_stdout: true)
      assert exit_code != 0, "Expected #{task.id} fixture to fail before agent repair"
    end
  end

  test "Round 2 eval tasks #7-#8 pass 2/2 through real AgentLoop and Tools" do
    assert {:ok, results} =
             Runner.run("eval/tasks",
               only: ["elixir-context-bugfix", "elixir-otp-timeout-leak"],
               samples: 1,
               ks: [1],
               llm: ScriptedRound2LLM,
               tool_executor: IexCode.Tools
             )

    assert length(results.tasks) == 2

    for task <- results.tasks do
      assert [sample] = task.samples

      assert sample.passed,
             "Expected #{task.id} to pass, got loop=#{inspect(sample.loop)} grade=#{inspect(sample.grade)}"

      assert sample.turns == 3
      assert sample.tool_calls >= 2
      refute File.exists?(sample.workdir)
    end

    assert results.aggregate.samples == 2
    assert results.aggregate.passed == 2
    assert results.aggregate.pass_rate == 1.0
    assert results.aggregate.pass_at_k == %{1 => 1.0}
  end
end

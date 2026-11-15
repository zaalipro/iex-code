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

          String.contains?(prompt, "lib/orders.ex") ->
            [
              %{id: "read-ledger", name: "read_file", args: %{"path" => "lib/ledger.ex"}},
              %{id: "read-orders", name: "read_file", args: %{"path" => "lib/orders.ex"}}
            ]

          String.contains?(prompt, "lib/job_coordinator.ex") ->
            [
              %{
                id: "read-job-coordinator",
                name: "read_file",
                args: %{"path" => "lib/job_coordinator.ex"}
              }
            ]

          String.contains?(prompt, "lib/ast_renamer.ex") ->
            [
              %{
                id: "read-ast-renamer",
                name: "read_file",
                args: %{"path" => "lib/ast_renamer.ex"}
              }
            ]

          String.contains?(prompt, "lib/jsonrpc_framer.ex") ->
            [
              %{
                id: "read-jsonrpc-framer",
                name: "read_file",
                args: %{"path" => "lib/jsonrpc_framer.ex"}
              }
            ]
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

          String.contains?(prompt, "lib/ast_renamer.ex") ->
            [
              %{
                id: "write-ast-renamer",
                name: "write_file",
                args: %{
                  "path" => "lib/ast_renamer.ex",
                  "content" => """
                  defmodule AstRenamer do
                    @moduledoc \"\"\"
                    AST-aware Elixir function renaming utility.
                    \"\"\"

                    @spec rename_function(String.t(), atom(), atom(), non_neg_integer()) ::
                            {:ok, String.t()} | {:error, term()}
                    def rename_function(source, old_name, new_name, arity)
                        when is_binary(source) and is_atom(old_name) and is_atom(new_name) and
                               is_integer(arity) and arity >= 0 do
                      with {:ok, ast} <- Code.string_to_quoted(source) do
                        updated_ast =
                          Macro.prewalk(ast, fn
                            {def_kind, def_meta, [{:when, when_meta, [{^old_name, fn_meta, args}, guard]}, body]}
                            when def_kind in [:def, :defp] and
                                   ((is_nil(args) and arity == 0) or
                                      (is_list(args) and length(args) == arity)) ->
                              {def_kind, def_meta,
                               [{:when, when_meta, [{new_name, fn_meta, args}, guard]}, body]}

                            {def_kind, def_meta, [{^old_name, fn_meta, args}, body]}
                            when def_kind in [:def, :defp] and
                                   ((is_nil(args) and arity == 0) or
                                      (is_list(args) and length(args) == arity)) ->
                              {def_kind, def_meta, [{new_name, fn_meta, args}, body]}

                            {:&, cap_meta, [{:/, slash_meta, [{^old_name, fn_meta, ctx}, ^arity]}]}
                            when is_atom(ctx) ->
                              {:&, cap_meta, [{:/, slash_meta, [{new_name, fn_meta, ctx}, arity]}]}

                            {:&, cap_meta,
                             [{:/, slash_meta, [{{:., dot_meta, [mod, ^old_name]}, call_meta, []}, ^arity]}]} ->
                              {:&, cap_meta,
                               [{:/, slash_meta, [{{:., dot_meta, [mod, new_name]}, call_meta, []}, arity]}]}

                            {{:., dot_meta, [mod, ^old_name]}, call_meta, args}
                            when is_list(args) and length(args) == arity ->
                              {{:., dot_meta, [mod, new_name]}, call_meta, args}

                            {^old_name, call_meta, args}
                            when is_list(args) and length(args) == arity ->
                              {new_name, call_meta, args}

                            other ->
                              other
                          end)

                        {:ok, Macro.to_string(updated_ast)}
                      end
                    end
                  end
                  """
                }
              }
            ]

          String.contains?(prompt, "lib/jsonrpc_framer.ex") ->
            [
              %{
                id: "write-jsonrpc-framer",
                name: "write_file",
                args: %{
                  "path" => "lib/jsonrpc_framer.ex",
                  "content" => """
                  defmodule JsonRpcFramer do
                    @moduledoc \"\"\"
                    Streaming Content-Length framer for JSON-RPC / LSP / MCP stdio transports.
                    \"\"\"

                    @default_max_bytes 1_048_576

                    @type t :: %{buffer: binary(), max_content_length: pos_integer()}

                    @spec new(keyword()) :: t()
                    def new(opts \\\\ []) do
                      %{
                        buffer: "",
                        max_content_length: Keyword.get(opts, :max_content_length, @default_max_bytes)
                      }
                    end

                    @spec encode(binary()) :: binary()
                    def encode(payload) when is_binary(payload) do
                      "Content-Length: \#{byte_size(payload)}\\r\\n\\r\\n" <> payload
                    end

                    @spec feed(t(), binary()) :: {:ok, [binary()], t()} | {:error, term(), t()}
                    def feed(%{buffer: buffer} = state, chunk) when is_binary(chunk) do
                      extract_frames(buffer <> chunk, state, [])
                    end

                    defp extract_frames(buffer, state, acc) do
                      case :binary.match(buffer, "\\r\\n\\r\\n") do
                        {header_len, 4} ->
                          header_block = binary_part(buffer, 0, header_len)
                          rest = binary_part(buffer, header_len + 4, byte_size(buffer) - header_len - 4)

                          case parse_content_length(header_block, state.max_content_length) do
                            {:ok, content_length} ->
                              if byte_size(rest) >= content_length do
                                payload = binary_part(rest, 0, content_length)
                                remaining = binary_part(rest, content_length, byte_size(rest) - content_length)
                                extract_frames(remaining, state, [payload | acc])
                              else
                                {:ok, Enum.reverse(acc), %{state | buffer: buffer}}
                              end

                            {:error, reason} ->
                              {:error, reason, %{state | buffer: ""}}
                          end

                        :nomatch ->
                          {:ok, Enum.reverse(acc), %{state | buffer: buffer}}
                      end
                    end

                    defp parse_content_length(header_block, max_bytes) do
                      headers =
                        header_block
                        |> String.split("\\r\\n", trim: true)
                        |> Enum.reduce(%{}, fn line, acc ->
                          case String.split(line, ":", parts: 2) do
                            [name, val] ->
                              Map.put(acc, name |> String.trim() |> String.downcase(), String.trim(val))

                            _ ->
                              acc
                          end
                        end)

                      case Map.fetch(headers, "content-length") do
                        :error ->
                          {:error, :missing_content_length}

                        {:ok, raw} ->
                          case Integer.parse(raw) do
                            {len, ""} when len >= 0 and len <= max_bytes -> {:ok, len}
                            {len, ""} when len > max_bytes -> {:error, :frame_too_large}
                            _ -> {:error, :invalid_content_length}
                          end
                      end
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

  test "all 10 eval tasks load cleanly and start in a genuinely failing state before agent execution" do
    assert {:ok, tasks} = Task.load_dir("eval/tasks")
    assert length(tasks) == 10

    expected_ids = [
      "elixir-ast-rename-refactor",
      "elixir-compile-repair",
      "elixir-context-bugfix",
      "elixir-genserver-bounded-state",
      "elixir-jsonrpc-frame-parser",
      "elixir-multi-file-contract",
      "elixir-otp-timeout-leak",
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

  test "full benchmark suite passes 10/10 through real AgentLoop and real Tools and cleans up workdirs" do
    assert {:ok, results} =
             Runner.run("eval/tasks",
               samples: 1,
               ks: [1],
               llm: ScriptedBenchmarkLLM,
               tool_executor: IexCode.Tools
             )

    assert length(results.tasks) == 10

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

    assert results.aggregate.samples == 10
    assert results.aggregate.passed == 10
    assert results.aggregate.pass_rate == 1.0
    assert results.aggregate.pass_at_k == %{1 => 1.0}

    assert results.by_category["bugfix"].pass_rate == 1.0
    assert results.by_category["refactor"].pass_rate == 1.0
    assert results.by_category["ambiguous_edit"].pass_rate == 1.0
    assert results.by_category["concurrency"].pass_rate == 1.0
    assert results.by_category["compile_repair"].pass_rate == 1.0
    assert results.by_category["general"].pass_rate == 1.0

    report = Runner.format_report(results)
    assert report =~ "eval: 10 task(s) x 1 sample(s)"
    assert report =~ "aggregate: 10/10 passed"

    decoded = results |> Runner.to_json_report() |> Jason.decode!()
    assert decoded["aggregate"]["passed"] == 10
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

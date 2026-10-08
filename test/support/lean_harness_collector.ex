defmodule IexCode.Test.LeanHarnessCollector do
  @moduledoc false

  def start do
    owner = self()
    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, [:iex_code, :repo, :query], &__MODULE__.query/4, owner)
    before_sample = sample()

    %{
      handler: handler,
      started: System.monotonic_time(:microsecond),
      before: before_sample
    }
  end

  def query(_event, measurements, metadata, owner) do
    if metadata.repo == IexCode.Repo do
      rows =
        case metadata.result do
          {:ok, %{num_rows: count}} when is_integer(count) -> count
          _ -> 0
        end

      select? = String.starts_with?(String.trim_leading(metadata.query), "SELECT")

      send(
        owner,
        {:lean_query,
         %{
           selected_rows: if(select?, do: rows, else: 0),
           message_rows: if(select? and metadata.source == "messages", do: rows, else: 0),
           authority_selects: if(select? and metadata.source == "runs", do: 1, else: 0),
           query_native: measurements.total_time
         }}
      )
    end
  end

  def finish(collector) do
    :telemetry.detach(collector.handler)
    elapsed = System.monotonic_time(:microsecond) - collector.started
    after_sample = sample()
    queries = drain([])

    %{
      query_count: length(queries),
      selected_rows: sum(queries, :selected_rows),
      loaded_message_rows: sum(queries, :message_rows),
      run_select_count: sum(queries, :authority_selects),
      query_time_us: System.convert_time_unit(sum(queries, :query_native), :native, :microsecond),
      wall_us: elapsed,
      process_memory_before_bytes: collector.before.memory,
      process_memory_after_bytes: after_sample.memory,
      vm_memory_before_bytes: collector.before.vm_memory,
      vm_memory_after_bytes: after_sample.vm_memory,
      reductions: after_sample.reductions - collector.before.reductions
    }
  end

  def measure(fun) do
    collector = start()

    try do
      result = fun.()
      {result, finish(collector)}
    after
      :telemetry.detach(collector.handler)
    end
  end

  def emit(scenario, parameters, metrics) do
    IO.puts(
      "LEAN_BENCH " <>
        Jason.encode!(%{
          schema: 1,
          scenario: scenario,
          parameters: parameters,
          metrics: metrics
        })
    )
  end

  defp sample do
    info = Map.new(Process.info(self(), [:memory, :reductions]))
    Map.put(info, :vm_memory, :erlang.memory(:total))
  end

  defp sum(queries, key), do: Enum.reduce(queries, 0, &(&1[key] + &2))

  defp drain(acc) do
    receive do
      {:lean_query, query} -> drain([query | acc])
    after
      0 -> acc
    end
  end
end

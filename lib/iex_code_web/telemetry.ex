defmodule IexCodeWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("iex_code.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("iex_code.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("iex_code.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("iex_code.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("iex_code.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # Terminal Metrics
      summary("iex_code.terminal.session_started.system_time",
        tags: [:session_id, :shell],
        unit: {:native, :millisecond},
        description: "Terminal PTY shell started timestamp"
      ),
      summary("iex_code.terminal.command_dispatched.system_time",
        tags: [:session_id, :agent_name],
        unit: {:native, :millisecond},
        description: "Terminal command dispatched timestamp"
      ),
      summary("iex_code.terminal.output_chunk.byte_size",
        tags: [:session_id],
        unit: {:byte, :byte},
        description: "Size of terminal output chunks streamed"
      ),
      summary("iex_code.terminal.command_completed.duration_ms",
        tags: [:session_id, :agent_name, :status],
        unit: {:native, :millisecond},
        description: "Duration of agent terminal command execution"
      ),
      summary("iex_code.terminal.command_completed.exit_code",
        tags: [:session_id, :agent_name],
        description: "Exit code of completed agent terminal commands"
      ),
      summary("iex_code.terminal.session_stopped.duration_ms",
        tags: [:session_id, :reason],
        unit: {:native, :millisecond},
        description: "Duration of terminal session lifecycle"
      )
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {IexCodeWeb, :count_users, []}
    ]
  end
end

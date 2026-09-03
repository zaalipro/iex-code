defmodule IexCode.Desktop.WindowSupervisor do
  @moduledoc """
  DynamicSupervisor managing native detached desktop windows (`Desktop.Window` instances).
  Ensures secondary detached tool windows run under supervisor isolation so that window
  crashes or manual dismissals do not take down the primary application node.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a desktop window under this supervisor.
  """
  def start_window(child_spec) do
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Terminates a desktop window child process.
  """
  def stop_window(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end
end

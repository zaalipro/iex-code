defmodule IexCode.Runs.Executor do
  @moduledoc """
  Typed production executor for durable coding runs.

  The dispatcher persists and claims a run before this module is invoked.  No
  executable closures are stored in the database: the persisted `kind` and
  `mode` select a known implementation here.
  """

  @callback execute(IexCode.Runs.Run.t(), (non_neg_integer(), String.t() -> any())) ::
              {:ok, term()} | {:error, term()}

  alias IexCode.Engine.SwarmCoordinator
  alias IexCode.Projects
  alias IexCode.Runs.Run

  @doc false
  def execute(%Run{} = run, progress) when is_function(progress, 2) do
    with :ok <- supported_run?(run),
         project <- Projects.get_project!(run.project_id) do
      progress.(5, "Preparing durable coding run")

      result = execute_typed(run, project.root_path)

      progress.(100, "Coding run finished")
      result
    end
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp supported_run?(%Run{kind: "coding_swarm", mode: mode})
       when mode in ["swarm", "workflow"],
       do: :ok

  defp supported_run?(%Run{kind: "analysis"}), do: :ok

  defp supported_run?(%Run{kind: kind, mode: mode}),
    do: {:error, {:unsupported_run, kind, mode}}

  defp execute_typed(%Run{kind: "coding_swarm"} = run, project_root) do
    run.session_id
    |> SwarmCoordinator.run(run.objective,
      project_root: project_root,
      run_id: run.id
    )
    |> normalize_swarm_result()
  end

  defp execute_typed(%Run{kind: "analysis"}, project_root) do
    with {:ok, entries} <- File.ls(project_root) do
      {:ok, %{project_root: project_root, entries: Enum.sort(entries)}}
    end
  end

  @doc false
  def normalize_swarm_result({:ok, %{cancelled: true}}), do: {:error, :cancelled}

  def normalize_swarm_result({:ok, %{metadata: metadata} = message}) when is_map(metadata) do
    case Map.get(metadata, :status) || Map.get(metadata, "status") do
      status when status in [:failed, "failed"] -> {:error, {:swarm_failed, message}}
      status when status in [:cancelled, :stopped, "cancelled", "stopped"] -> {:error, :cancelled}
      _status -> {:ok, message}
    end
  end

  def normalize_swarm_result(result), do: result
end

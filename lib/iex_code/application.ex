defmodule IexCode.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        IexCodeWeb.Telemetry,
        IexCode.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:iex_code, :ecto_repos), skip: skip_migrations?()},
        IexCode.DatabasePermissions,
        {DNSCluster, query: Application.get_env(:iex_code, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: IexCode.PubSub},
        {Registry, keys: :unique, name: IexCode.SessionRegistry},
        {Registry, keys: :unique, name: IexCode.Engine.AgentRegistry},
        {Task.Supervisor, name: IexCode.TaskSupervisor},
        IexCode.WorkspaceLocks,
        IexCode.Engine.SessionSupervisor,
        IexCode.Engine.AgentSupervisor,
        IexCode.Tools.TerminalSupervisor,
        {IexCode.Tools.MultiPatch.Snapshot.Owner, []},
        run_dispatcher_child(),
        kanban_scheduler_child(),
        IexCodeWeb.Endpoint,
        desktop_child()
      ]
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: IexCode.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp desktop_child do
    if Application.get_env(:iex_code, :start_desktop_window, false) do
      {Desktop.Window,
       [
         app: :iex_code,
         id: IexCodeWindow,
         title: "IexCode - Desktop AI Coding Harness",
         size: {1440, 920},
         url: &IexCodeWeb.Endpoint.url/0
       ]}
    else
      nil
    end
  end

  defp run_dispatcher_child do
    if Application.get_env(:iex_code, :start_run_dispatcher, true) do
      IexCode.Runs.RunDispatcher
    end
  end

  defp kanban_scheduler_child do
    if Application.get_env(:iex_code, :start_kanban_scheduler, true) do
      IexCode.Kanban.Scheduler
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    IexCodeWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are skipped when testing.
    # They run in dev and in releases (including desktop mode),
    # so the bundled database is always up to date at boot.
    System.get_env("MIX_ENV") == "test"
  end
end

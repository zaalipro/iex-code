defmodule IexCode.Kanban do
  @moduledoc """
  Context module for managing Kanban tasks, agent task execution,
  schedules, and real-time PubSub updates.
  """
  import Ecto.Query
  alias IexCode.Repo
  alias IexCode.Kanban.Task
  alias IexCode.Sessions

  def list_tasks(project_id, filters \\ %{}) do
    query = from(t in Task, where: t.project_id == ^project_id, order_by: [asc: t.inserted_at])

    query =
      Enum.reduce(filters, query, fn
        {"status", status}, q when status not in ["", nil] ->
          from(t in q, where: t.status == ^status)

        {"priority", priority}, q when priority not in ["", nil] ->
          from(t in q, where: t.priority == ^priority)

        {"assignee", assignee}, q when assignee not in ["", nil] ->
          from(t in q, where: t.assignee == ^assignee)

        {"search", term}, q when term not in ["", nil] ->
          search = "%#{term}%"
          from(t in q, where: like(t.title, ^search) or like(t.description, ^search))

        _, q ->
          q
      end)

    Repo.all(query)
  end

  def list_tasks_by_status(project_id) do
    tasks = list_tasks(project_id)
    grouped = Enum.group_by(tasks, & &1.status)

    Enum.into(Task.statuses(), %{}, fn status ->
      {status, Map.get(grouped, status, [])}
    end)
  end

  def get_task!(id), do: Repo.get!(Task, id)

  def get_task(id), do: Repo.get(Task, id)

  def create_task(attrs) do
    %Task{}
    |> Task.changeset(sanitize_attrs(attrs))
    |> Repo.insert()
    |> case do
      {:ok, task} ->
        broadcast(task.project_id, {:task_created, task})
        {:ok, task}

      error ->
        error
    end
  end

  def update_task(%Task{} = task, attrs) do
    task
    |> Task.changeset(sanitize_attrs(attrs))
    |> Repo.update()
    |> case do
      {:ok, updated_task} ->
        broadcast(updated_task.project_id, {:task_updated, updated_task})
        {:ok, updated_task}

      error ->
        error
    end
  end

  def move_task_status(%Task{} = task, new_status)
      when new_status in ~w(triage todo scheduled ready running blocked review done) do
    update_task(task, %{status: new_status})
  end

  def delete_task(%Task{} = task) do
    project_id = task.project_id

    case Repo.delete(task) do
      {:ok, deleted_task} ->
        broadcast(project_id, {:task_deleted, deleted_task})
        {:ok, deleted_task}

      error ->
        error
    end
  end

  def change_task(%Task{} = task, attrs \\ %{}) do
    Task.changeset(task, sanitize_attrs(attrs))
  end

  def claim_task(%Task{} = task, assignee \\ "default") do
    worker_pid = inspect(self())

    update_task(task, %{
      status: "running",
      assignee: assignee,
      worker_pid: worker_pid,
      metadata:
        Map.merge(task.metadata || %{}, %{
          "claimed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "claimed_by" => assignee
        })
    })
  end

  def estimate_effort(%Task{} = task) do
    estimate =
      cond do
        task.steps_total > 5 -> "25-45m (High effort)"
        task.steps_total > 2 -> "10-20m (Medium effort)"
        true -> "3-5m (Low effort)"
      end

    update_task(task, %{estimate: estimate})
  end

  def broadcast(project_id, event) do
    Phoenix.PubSub.broadcast(IexCode.PubSub, "kanban:#{project_id}", event)
  end

  def subscribe(project_id) do
    Phoenix.PubSub.subscribe(IexCode.PubSub, "kanban:#{project_id}")
  end

  defp sanitize_attrs(attrs) when is_map(attrs) do
    Sessions.sanitize_utf8(attrs)
  end

  defp sanitize_attrs(attrs), do: attrs
end

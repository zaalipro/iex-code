defmodule IexCode.Kanban do
  @moduledoc """
  Context module for managing Kanban tasks, agent task execution,
  schedules, and real-time PubSub updates.
  """
  import Ecto.Query
  alias IexCode.Repo
  alias IexCode.Kanban.Task
  alias IexCode.Sessions

  # A running task whose claim is older than this can be re-claimed by another worker.
  @stale_claim_minutes 30

  def list_tasks(project_id, filters \\ %{}) do
    query =
      from(t in Task,
        where: t.project_id == ^project_id,
        order_by: [
          asc:
            fragment(
              "CASE WHEN ? = 'critical' THEN 0 WHEN ? = 'high' THEN 1 WHEN ? = 'medium' THEN 2 ELSE 3 END",
              t.priority,
              t.priority,
              t.priority
            ),
          asc: t.inserted_at
        ]
      )

    query =
      Enum.reduce(filters, query, fn
        {"status", status}, q when status not in ["", nil] ->
          from(t in q, where: t.status == ^status)

        {"priority", priority}, q when priority not in ["", nil] ->
          from(t in q, where: t.priority == ^priority)

        {"assignee", assignee}, q when assignee not in ["", nil] ->
          from(t in q, where: t.assignee == ^assignee)

        {"search", term}, q when term not in ["", nil] ->
          escaped =
            term
            |> String.replace("\\", "\\\\")
            |> String.replace("%", "\\%")
            |> String.replace("_", "\\_")

          pattern = "%#{escaped}%"

          from(t in q,
            where:
              fragment("? LIKE ? ESCAPE '\\'", t.title, ^pattern) or
                fragment("? LIKE ? ESCAPE '\\'", t.description, ^pattern)
          )

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
    Repo.retry_on_busy(fn ->
      %Task{}
      |> Task.changeset(sanitize_attrs(attrs))
      |> Repo.insert()
    end)
    |> case do
      {:ok, task} ->
        broadcast(task.project_id, {:task_created, task})
        {:ok, task}

      error ->
        error
    end
  end

  def update_task(%Task{} = task, attrs) do
    Repo.retry_on_busy(fn ->
      task
      |> Task.changeset(sanitize_attrs(attrs))
      |> Repo.update()
    end)
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

  def move_task_status(%Task{}, _invalid_status), do: {:error, :invalid_status}
  def move_task_status(_invalid_task, _status), do: {:error, :invalid_task}

  def delete_task(%Task{} = task) do
    project_id = task.project_id

    case Repo.retry_on_busy(fn -> Repo.delete(task) end) do
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

  @doc """
  Atomically claims a task for the given assignee.

  The claim is a single conditional UPDATE: it only succeeds when the task is
  not already running, or when an existing claim is older than
  #{@stale_claim_minutes} minutes (stale-claim reclamation). Returns
  `{:ok, task}` on success or `{:error, :already_claimed}` when another worker
  holds a fresh claim.
  """
  def claim_task(%Task{} = task, assignee \\ "default") do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    stale_before = DateTime.add(now, -@stale_claim_minutes * 60, :second)
    worker_pid = inspect(self())

    {count, _} =
      from(t in Task,
        where: t.id == ^task.id,
        where: t.status != "running" or is_nil(t.claimed_at) or t.claimed_at < ^stale_before
      )
      |> Repo.update_all(
        set: [
          status: "running",
          assignee: assignee,
          worker_pid: worker_pid,
          claimed_at: now,
          updated_at: now
        ]
      )

    case count do
      1 ->
        claimed = get_task!(task.id)
        broadcast(claimed.project_id, {:task_updated, claimed})
        {:ok, claimed}

      0 ->
        {:error, :already_claimed}
    end
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

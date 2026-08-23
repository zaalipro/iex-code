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

  def move_task_status(%Task{} = task, new_status) do
    normalized = normalize_status(new_status)

    if normalized in Task.statuses() do
      update_task(task, %{status: normalized})
    else
      {:error, :invalid_status}
    end
  end

  def move_task_status(_invalid_task, _status), do: {:error, :invalid_task}

  defp normalize_status(status) when is_binary(status) do
    case String.downcase(String.trim(status)) do
      "in_progress" -> "running"
      "in-progress" -> "running"
      "failed" -> "blocked"
      "complete" -> "done"
      "completed" -> "done"
      s -> s
    end
  end

  defp normalize_status(_), do: nil

  @doc """
  Adds a subtask to a task and recomputes completion progress.
  """
  def add_subtask(%Task{} = task, subtask_params) do
    title =
      case subtask_params do
        %{"title" => t} -> t
        %{title: t} -> t
        t when is_binary(t) -> t
        _ -> ""
      end
      |> to_string()
      |> String.trim()

    if title == "" do
      {:error, :empty_title}
    else
      subtask = %{
        "id" => Ecto.UUID.generate(),
        "title" => title,
        "completed" => false
      }

      current = task.subtasks || []
      update_task(task, %{subtasks: current ++ [subtask]})
    end
  end

  def add_subtask(task_id, subtask_params) when is_binary(task_id) do
    case get_task(task_id) do
      nil -> {:error, :not_found}
      task -> add_subtask(task, subtask_params)
    end
  end

  @doc """
  Toggles the completion status of a subtask.
  """
  def toggle_subtask(%Task{} = task, subtask_id) do
    target_id = to_string(subtask_id)
    current = task.subtasks || []

    updated =
      Enum.map(current, fn s ->
        sid = to_string(s["id"] || s[:id])

        if sid == target_id do
          done? = s["completed"] == true or s[:completed] == true
          Map.put(s, "completed", not done?)
        else
          s
        end
      end)

    update_task(task, %{subtasks: updated})
  end

  def toggle_subtask(task_id, subtask_id) when is_binary(task_id) do
    case get_task(task_id) do
      nil -> {:error, :not_found}
      task -> toggle_subtask(task, subtask_id)
    end
  end

  @doc """
  Deletes a subtask from a task.
  """
  def delete_subtask(%Task{} = task, subtask_id) do
    target_id = to_string(subtask_id)
    current = task.subtasks || []

    updated =
      Enum.reject(current, fn s ->
        sid = to_string(s["id"] || s[:id])
        sid == target_id
      end)

    update_task(task, %{subtasks: updated})
  end

  def delete_subtask(task_id, subtask_id) when is_binary(task_id) do
    case get_task(task_id) do
      nil -> {:error, :not_found}
      task -> delete_subtask(task, subtask_id)
    end
  end

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

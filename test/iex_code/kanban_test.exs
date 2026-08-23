defmodule IexCode.KanbanTest do
  use IexCode.DataCase, async: true
  alias IexCode.{Kanban, Projects, Sessions}

  setup do
    {:ok, project} =
      Projects.create_project(%{name: "Kanban Test Project", root_path: "/tmp/kanban_test"})

    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Test Session"})
    {:ok, project: project, session: session}
  end

  test "creates, lists, and filters kanban tasks", %{project: project, session: session} do
    attrs = %{
      project_id: project.id,
      session_id: session.id,
      title: "Fix transaction status",
      description: "Reconcile payment webhook",
      status: "ready",
      priority: "high",
      assignee: "coder",
      steps_total: 4,
      steps_completed: 2,
      tags: ["FinPay", "Bug"]
    }

    assert {:ok, task} = Kanban.create_task(attrs)
    assert task.title == "Fix transaction status"
    assert task.status == "ready"
    assert task.priority == "high"
    assert task.tags == ["FinPay", "Bug"]

    tasks = Kanban.list_tasks(project.id)
    assert length(tasks) >= 1

    by_status = Kanban.list_tasks_by_status(project.id)
    assert Map.has_key?(by_status, "ready")
    assert Enum.any?(by_status["ready"], &(&1.id == task.id))
  end

  test "moves task status and claims task with worker PID", %{project: project, session: session} do
    {:ok, task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "say hi to me <3",
        status: "ready"
      })

    assert {:ok, claimed} = Kanban.claim_task(task, "coder")
    assert claimed.status == "running"
    assert claimed.assignee == "coder"
    assert claimed.worker_pid != nil

    assert {:ok, completed} = Kanban.move_task_status(claimed, "done")
    assert completed.status == "done"
  end

  test "estimates task effort", %{project: project, session: session} do
    {:ok, task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "AST search engine",
        steps_total: 6
      })

    assert {:ok, estimated} = Kanban.estimate_effort(task)
    assert estimated.estimate =~ "High effort"
  end

  test "normalizes agile statuses when moving task status", %{
    project: project,
    session: session
  } do
    {:ok, task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Agile status normalization",
        status: "todo"
      })

    assert {:ok, running} = Kanban.move_task_status(task, "in_progress")
    assert running.status == "running"

    assert {:ok, blocked} = Kanban.move_task_status(running, "failed")
    assert blocked.status == "blocked"

    assert {:ok, done} = Kanban.move_task_status(blocked, "complete")
    assert done.status == "done"

    assert {:ok, done2} = Kanban.move_task_status(done, "completed")
    assert done2.status == "done"
  end

  test "manages subtasks and dynamically computes steps_completed and steps_total", %{
    project: project,
    session: session
  } do
    {:ok, task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Subtasks Feature Test",
        status: "todo"
      })

    assert task.subtasks == []
    assert task.steps_total == 0
    assert task.steps_completed == 0

    # Add 1st subtask
    assert {:ok, task1} = Kanban.add_subtask(task, %{"title" => "Write schema"})
    assert length(task1.subtasks) == 1
    assert task1.steps_total == 1
    assert task1.steps_completed == 0
    [subtask1] = task1.subtasks

    # Add 2nd subtask by ID
    assert {:ok, task2} = Kanban.add_subtask(task1.id, "Add LiveView event handlers")
    assert length(task2.subtasks) == 2
    assert task2.steps_total == 2
    assert task2.steps_completed == 0
    [_, subtask2] = task2.subtasks

    # Toggle 1st subtask to completed
    assert {:ok, task3} = Kanban.toggle_subtask(task2, subtask1["id"])
    assert task3.steps_total == 2
    assert task3.steps_completed == 1

    # Toggle 2nd subtask by task_id string
    assert {:ok, task4} = Kanban.toggle_subtask(task3.id, subtask2["id"])
    assert task4.steps_total == 2
    assert task4.steps_completed == 2

    # Untoggle 1st subtask
    assert {:ok, task5} = Kanban.toggle_subtask(task4, subtask1["id"])
    assert task5.steps_total == 2
    assert task5.steps_completed == 1

    # Delete 2nd subtask
    assert {:ok, task6} = Kanban.delete_subtask(task5.id, subtask2["id"])
    assert length(task6.subtasks) == 1
    assert task6.steps_total == 1
    assert task6.steps_completed == 0

    # Reject empty subtask
    assert {:error, :empty_title} = Kanban.add_subtask(task6, %{"title" => "   "})
  end
end

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

  test "returns error for invalid task status or invalid task", %{
    project: project,
    session: session
  } do
    {:ok, task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Invalid status test",
        status: "ready"
      })

    assert {:error, :invalid_status} = Kanban.move_task_status(task, "custom_status_xyz")
    assert {:error, :invalid_status} = Kanban.move_task_status(task, "")
    assert {:error, :invalid_status} = Kanban.move_task_status(task, nil)
    assert {:error, :invalid_task} = Kanban.move_task_status(nil, "done")
  end
end

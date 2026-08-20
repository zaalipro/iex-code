defmodule IexCode.SessionsTest do
  use IexCode.DataCase, async: false
  alias IexCode.{Projects, Sessions}

  test "creates projects, sessions, messages, and operations" do
    {:ok, project} =
      Projects.create_project(%{name: "Test Project", root_path: "/tmp/test_project"})

    assert project.name == "Test Project"

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Test Session",
        swarm_mode: true
      })

    assert session.swarm_mode == true

    {:ok, msg} =
      Sessions.create_message(%{
        session_id: session.id,
        role: "user",
        content: "Build an API"
      })

    assert msg.content == "Build an API"

    {:ok, op} =
      Sessions.create_operation(%{
        session_id: session.id,
        agent_name: "CoderAgent",
        op_type: "write_file",
        title: "Writing lib/api.ex",
        status: "running",
        progress: 50
      })

    assert op.progress == 50

    ops = Sessions.list_operations(session.id)
    assert length(ops) == 1
  end
end

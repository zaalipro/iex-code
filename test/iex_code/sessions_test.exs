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

  test "a persisted session cannot be reparented to another project" do
    {:ok, project} =
      Projects.create_project(%{name: "Session owner", root_path: "/tmp/session_owner"})

    {:ok, other_project} =
      Projects.create_project(%{name: "Other owner", root_path: "/tmp/other_session_owner"})

    {:ok, session} =
      Sessions.create_session(%{project_id: project.id, title: "Owned session"})

    assert {:error, %Ecto.Changeset{} = changeset} =
             Sessions.update_session(session, %{project_id: other_project.id})

    assert {"cannot be changed after creation", _metadata} = changeset.errors[:project_id]
    assert Sessions.get_session(session.id).project_id == project.id
  end
end

defmodule IexCode.Tools.SemanticCodeSearchTest do
  use IexCode.DataCase, async: false

  alias IexCode.Projects
  alias IexCode.Tools

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "semantic_tool_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    File.write!(Path.join(tmp_dir, "lib/greeter.ex"), """
    defmodule Greeter do
      @doc "Greets someone by name"
      def hello(name), do: "Hello, \#{name}!"

      @doc "Says goodbye"
      def goodbye(name), do: "Goodbye, \#{name}!"
    end
    """)

    {:ok, project} =
      Projects.create_project(%{
        name: "Greeter Project",
        root_path: tmp_dir
      })

    on_exit(fn ->
      File.rm_rf(tmp_dir)
    end)

    %{project: project, root_path: tmp_dir}
  end

  test "executes semantic_code_search tool and returns ranked matches", %{root_path: root} do
    assert {:ok, result} =
             Tools.execute(
               "semantic_code_search",
               %{"query" => "greeting someone with a friendly message", "threshold" => 0.1},
               root
             )

    assert is_binary(result)
    assert result =~ "lib/greeter.ex"
    assert result =~ "Greets" or result =~ "hello" or result =~ "Greeter"
  end

  test "supports mode parameter (lexical, vector, hybrid) and rejects invalid mode", %{
    root_path: root,
    project: project
  } do
    assert {:ok, lexical_out} =
             Tools.execute(
               "semantic_code_search",
               %{
                 "query" => "Greeter goodbye",
                 "mode" => "lexical",
                 "threshold" => 0.01
               },
               root
             )

    assert lexical_out =~ "lib/greeter.ex"
    assert lexical_out =~ "goodbye"

    assert {:ok, hybrid_out} =
             Tools.execute(
               "semantic_code_search",
               %{
                 "query" => "hello name",
                 "mode" => "hybrid",
                 "threshold" => 0.01
               },
               root
             )

    assert hybrid_out =~ "lib/greeter.ex"

    assert {:error, err} =
             Tools.execute(
               "semantic_code_search",
               %{"query" => "hello", "mode" => "nonexistent_mode"},
               root
             )

    assert err =~ "invalid_mode"

    # Also test rename_symbol workspace lock enforcement on a managed project:
    # dry_run succeeds even while another owner holds an exclusive project lock,
    # whereas non-dry-run rename_symbol fails closed with {:workspace_lock_waiting, _}.
    assert {:ok, handle} =
             IexCode.WorkspaceLocks.acquire(
               project,
               [{:project, :exclusive}],
               owner_id: "external-lock-holder"
             )

    try do
      assert {:ok, dry_preview} =
               Tools.execute(
                 "rename_symbol",
                 %{
                   "symbol" => "Greeter.hello/1",
                   "new_name" => "greet_user",
                   "dry_run" => true,
                   "project_id" => project.id
                 },
                 root
               )

      assert dry_preview =~ "Dry run: would rename"

      assert {:error, {:workspace_lock_waiting, _locks}} =
               Tools.execute(
                 "rename_symbol",
                 %{
                   "symbol" => "Greeter.hello/1",
                   "new_name" => "greet_user",
                   "project_id" => project.id
                 },
                 root
               )
    after
      IexCode.WorkspaceLocks.release(handle)
    end
  end
end

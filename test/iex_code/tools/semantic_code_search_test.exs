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
end

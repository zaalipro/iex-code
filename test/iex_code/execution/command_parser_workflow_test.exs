defmodule IexCode.Execution.CommandParserWorkflowTest do
  use ExUnit.Case, async: true

  alias IexCode.Execution.{CommandError, CommandParser, Intent}

  describe "/create-workflow command parsing" do
    test "parses /create-workflow without arguments into create_workflow intent" do
      assert {:ok,
              %Intent{
                kind: :create_workflow,
                objective: nil,
                durability: :none,
                mode: :workflow,
                raw_command: "/create-workflow"
              }} = CommandParser.parse("/create-workflow")
    end

    test "parses /create-workflow with objective prompt" do
      prompt = "Build full-cycle OAuth2 PKCE login flow"

      assert {:ok,
              %Intent{
                kind: :create_workflow,
                objective: ^prompt,
                durability: :none,
                mode: :workflow,
                raw_command: "/create-workflow"
              }} = CommandParser.parse("/create-workflow #{prompt}")
    end

    test "trims whitespace in /create-workflow objective" do
      assert {:ok, %Intent{objective: "Research Elixir 1.18 features"}} =
               CommandParser.parse("   /create-workflow   Research Elixir 1.18 features   ")
    end
  end

  describe "/workflows command parsing" do
    test "parses /workflows alone into navigate intent for workflows tab" do
      assert {:ok,
              %Intent{
                kind: :navigate,
                objective: "workflows",
                durability: :none,
                mode: :navigation,
                raw_command: "/workflows"
              }} = CommandParser.parse("/workflows")
    end

    test "rejects unexpected arguments for /workflows" do
      assert {:error,
              %CommandError{
                code: :unexpected_arguments,
                command: "/workflows"
              }} = CommandParser.parse("/workflows some_argument")
    end
  end

  describe "command help and registry" do
    test "includes /create-workflow and /workflows in supported commands" do
      supported = CommandParser.supported_commands()
      assert "/create-workflow" in supported
      assert "/workflows" in supported
    end

    test "catalogues command help for both workflows commands" do
      help = CommandParser.command_help()

      create_help = Enum.find(help, &(&1.command == "/create-workflow"))
      assert create_help != nil
      assert create_help.usage =~ "/create-workflow"
      assert create_help.summary =~ "workflow builder"

      workflows_help = Enum.find(help, &(&1.command == "/workflows"))
      assert workflows_help != nil
      assert workflows_help.usage == "/workflows"
      assert workflows_help.summary =~ "workflows"
    end
  end
end

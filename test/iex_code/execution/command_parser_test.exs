defmodule IexCode.Execution.CommandParserTest do
  use ExUnit.Case, async: true

  alias IexCode.Execution.{CommandError, CommandParser, Intent}

  describe "ordinary and explicitly interactive prompts" do
    test "ordinary text becomes an interactive prompt" do
      assert {:ok,
              %Intent{
                kind: :prompt,
                objective: "explain this module",
                durability: :interactive,
                mode: :single,
                draft?: false,
                raw_command: nil,
                source: "composer"
              }} = CommandParser.parse("  explain this module  ")
    end

    test "chat aliases require and retain their exact command token" do
      for command <- ["/chat", "/ask"] do
        assert {:ok, intent} = CommandParser.parse("\t#{command}\nreview lib/foo.ex\t")
        assert intent.kind == :prompt
        assert intent.objective == "review lib/foo.ex"
        assert intent.durability == :interactive
        assert intent.mode == :single
        assert intent.raw_command == command
      end
    end

    test "source is bounded and normalized" do
      assert {:ok, intent} = CommandParser.parse("hello", source: :mix_cli)
      assert intent.source == "mix_cli"

      assert {:ok, intent} =
               CommandParser.parse("hello", source: String.duplicate("s", 150))

      assert byte_size(intent.source) == 100
      assert {:ok, %{source: "composer"}} = CommandParser.parse("hello", source: "  ")
    end
  end

  describe "durable commands" do
    test "run, swarm, and goal have exact typed semantics" do
      cases = [
        {"/run inspect the repository", :run, :single},
        {"/swarm implement the feature", :swarm, :swarm},
        {"/goal ship the release", :goal, :swarm}
      ]

      for {input, kind, mode} <- cases do
        assert {:ok, intent} = CommandParser.parse(input)
        assert intent.kind == kind
        assert intent.durability == :durable
        assert intent.mode == mode
        assert intent.draft? == false
        assert intent.objective != ""
      end
    end

    test "goal draft is an exact leading option" do
      assert {:ok, intent} = CommandParser.parse("/goal --draft preserve this objective")
      assert intent.kind == :goal
      assert intent.objective == "preserve this objective"
      assert intent.draft?

      assert_error("/goal --draft", :missing_objective, "/goal")
      assert_error("/goal --drafted nope", :invalid_option, "/goal")
      assert_error("/goal --unknown nope", :invalid_option, "/goal")
    end

    test "research accepts no level or one exact level option" do
      assert {:ok, plain} = CommandParser.parse("/research compare schedulers")
      assert plain.kind == :research
      assert plain.mode == :research
      assert plain.level == nil

      for level <- ~w(low medium high ultra) do
        assert {:ok, intent} =
                 CommandParser.parse("/research --level #{level} compare schedulers")

        assert intent.kind == :research
        assert intent.level == level
        assert intent.objective == "compare schedulers"
      end
    end

    test "research level failures are typed" do
      assert_error("/research --level", :invalid_level, "/research")
      assert_error("/research --level extreme objective", :invalid_level, "/research")
      assert_error("/research --level LOW objective", :invalid_level, "/research")
      assert_error("/research --level low", :missing_objective, "/research")
      assert_error("/research --depth high objective", :invalid_option, "/research")
      assert_error("/research --level=high objective", :invalid_option, "/research")
    end

    test "commands which execute work reject empty objectives" do
      for command <- ~w(/chat /ask /run /swarm /goal /research) do
        assert_error("  #{command}\n ", :missing_objective, command)
      end
    end
  end

  describe "research attachment commands" do
    test "picker and attachment intents are distinct" do
      assert {:ok,
              %Intent{
                kind: :research_picker,
                durability: :none,
                mode: :research,
                attachment_id: nil
              }} = CommandParser.parse("/deep_research")

      assert {:ok,
              %Intent{
                kind: :research_attachment,
                attachment_id: 42,
                durability: :none,
                mode: :research
              }} = CommandParser.parse("/deep_research 42")
    end

    test "accepts the largest signed SQLite integer without unsafe conversion" do
      maximum = 9_223_372_036_854_775_807

      assert {:ok, %{attachment_id: ^maximum}} =
               CommandParser.parse("/deep_research #{maximum}")
    end

    test "rejects malformed or oversized attachment ids" do
      invalid = [
        "/deep_research 0",
        "/deep_research -1",
        "/deep_research +1",
        "/deep_research 01",
        "/deep_research 1 2",
        "/deep_research nope",
        "/deep_research 9223372036854775808",
        "/deep_research #{String.duplicate("9", 10_000)}"
      ]

      for input <- invalid do
        assert_error(input, :invalid_attachment_id, "/deep_research")
      end
    end
  end

  describe "non-executing commands" do
    test "kanban is exact navigation and help is typed" do
      assert {:ok,
              %Intent{
                kind: :navigate,
                objective: "kanban",
                durability: :none,
                mode: :navigation
              }} = CommandParser.parse("/kanban")

      assert {:ok, %Intent{kind: :help, mode: :help, durability: :none}} =
               CommandParser.parse("/help")

      assert_error("/kanban now", :unexpected_arguments, "/kanban")
      assert_error("/help commands", :unexpected_arguments, "/help")
    end

    test "help is an ordered, exact command contract rather than a names-only list" do
      catalog = CommandParser.command_help()

      assert Enum.map(catalog, & &1.command) == CommandParser.supported_commands()
      assert Enum.all?(catalog, &(&1.usage != "" and &1.summary != ""))

      help = CommandParser.help_text()
      assert help =~ "Ordinary text follows the selected Interactive or Background dispatch mode"
      assert help =~ "/run <objective> — Queue a durable single-agent run."
      assert help =~ "/swarm <objective> — Queue a durable multi-agent coding swarm."
      assert help =~ "/goal [--draft] <objective>"
      assert help =~ "/research [--level low|medium|high|ultra] <objective>"
      assert help =~ "/deep_research [result_number]"
    end
  end

  describe "strict command boundaries" do
    test "never prefix-matches or case-folds command names" do
      invalid = ~w(
        /researcher
        /swarming
        /goalkeeper
        /running
        /deep_researcher
        /kanban-board
        /Goal
        /RESEARCH
        /
      )

      for command <- invalid do
        assert {:error,
                %CommandError{
                  code: :unknown_command,
                  command: ^command,
                  supported_commands: supported
                }} = CommandParser.parse("#{command} objective")

        assert supported == CommandParser.supported_commands()
      end
    end

    test "unknown command message provides discoverable supported commands" do
      assert {:error, %CommandError{} = error} = CommandParser.parse("/does_not_exist work")
      assert error.message =~ "/goal"
      assert error.message =~ "/research"
      assert error.message =~ "/help"
      assert error.message =~ "lowercase and exact"
    end

    test "missing-objective errors include exact usage" do
      assert {:error, %CommandError{} = goal} = CommandParser.parse("/goal")
      assert goal.message =~ "Usage: /goal [--draft] <objective>"

      assert {:error, %CommandError{} = research} =
               CommandParser.parse("/research --level high")

      assert research.message =~
               "Usage: /research [--level low|medium|high|ultra] <objective>"
    end
  end

  describe "input boundaries" do
    test "accepts exactly 100 KB and rejects one byte more" do
      maximum = String.duplicate("a", CommandParser.max_input_bytes())
      assert {:ok, %{objective: ^maximum}} = CommandParser.parse(maximum)

      assert {:error, %CommandError{code: :input_too_large}} =
               CommandParser.parse(maximum <> "b")
    end

    test "the raw boundary is checked before trimming" do
      input = " " <> String.duplicate("a", CommandParser.max_input_bytes())
      assert_error(input, :input_too_large, nil)
    end

    test "invalid values and invalid UTF-8 fail without raising" do
      for invalid <- [nil, 1, %{}, [], :prompt] do
        assert_error(invalid, :invalid_input, nil)
      end

      assert_error(<<255, 254>>, :invalid_encoding, nil)
      assert_error(" \n\t ", :empty_input, nil)
    end
  end

  describe "teamwork and boost commands" do
    test "parses standalone /teamwork command" do
      assert {:ok, intent} = CommandParser.parse("/teamwork Decompose data pipeline")
      assert intent.kind == :teamwork
      assert intent.teamwork? == true
      assert intent.objective == "Decompose data pipeline"
      assert intent.durability == :durable
    end

    test "parses /teamwork with explicit pattern option" do
      assert {:ok, intent} =
               CommandParser.parse(
                 "/teamwork --pattern root_cause_and_fix Investigate memory leak"
               )

      assert intent.kind == :teamwork
      assert intent.teamwork? == true
      assert intent.blueprint_pattern == "root_cause_and_fix"
      assert intent.objective == "Investigate memory leak"
    end

    test "parses standalone /teamwork without objective as modal trigger" do
      assert {:ok, intent} = CommandParser.parse("/teamwork")
      assert intent.kind == :teamwork
      assert intent.objective == nil
      assert intent.durability == :none
      assert intent.teamwork? == true
    end

    test "parses standalone /boost command as durable boosted run" do
      assert {:ok, intent} =
               CommandParser.parse("/boost Maximize reasoning effort on AST refactor")

      assert intent.kind == :run
      assert intent.boost? == true
      assert intent.objective == "Maximize reasoning effort on AST refactor"
      assert intent.durability == :durable
    end

    test "parses compound chained commands /teamwork /boost /goal" do
      assert {:ok, intent} =
               CommandParser.parse("/teamwork /boost /goal Build resilient payment webhook")

      assert intent.kind == :goal
      assert intent.mode == :swarm
      assert intent.durability == :durable
      assert intent.boost? == true
      assert intent.teamwork? == true
      assert intent.objective == "Build resilient payment webhook"
    end

    test "parses compound chained commands in alternative order /boost /teamwork /swarm" do
      assert {:ok, intent} =
               CommandParser.parse("/boost /teamwork /swarm Parallelize data processing jobs")

      assert intent.kind == :swarm
      assert intent.mode == :swarm
      assert intent.durability == :durable
      assert intent.boost? == true
      assert intent.teamwork? == true
      assert intent.objective == "Parallelize data processing jobs"
    end

    test "parses /teamwork with --pattern chained with /boost /goal" do
      assert {:ok, intent} =
               CommandParser.parse(
                 "/teamwork --pattern root_cause_and_fix /boost /goal Diagnose memory spike"
               )

      assert intent.kind == :goal
      assert intent.mode == :swarm
      assert intent.durability == :durable
      assert intent.boost? == true
      assert intent.teamwork? == true
      assert intent.blueprint_pattern == "root_cause_and_fix"
      assert intent.objective == "Diagnose memory spike"
    end

    test "parses /teamwork with --boost flag and chained /goal" do
      assert {:ok, intent} =
               CommandParser.parse("/teamwork --boost /goal Fix race conditions")

      assert intent.kind == :goal
      assert intent.mode == :swarm
      assert intent.boost? == true
      assert intent.teamwork? == true
      assert intent.objective == "Fix race conditions"
    end

    test "parses /teamwork with --pattern, --boost and shorthand flags" do
      assert {:ok, intent1} =
               CommandParser.parse(
                 "/teamwork --pattern distributed_coding --boost /goal Parallel workers"
               )

      assert intent1.kind == :goal
      assert intent1.boost? == true
      assert intent1.teamwork? == true
      assert intent1.blueprint_pattern == "distributed_coding"
      assert intent1.objective == "Parallel workers"

      assert {:ok, intent2} =
               CommandParser.parse("/teamwork --pattern=root_cause_and_fix -b /goal Trace leak")

      assert intent2.kind == :goal
      assert intent2.boost? == true
      assert intent2.teamwork? == true
      assert intent2.blueprint_pattern == "root_cause_and_fix"
      assert intent2.objective == "Trace leak"

      assert {:ok, intent3} =
               CommandParser.parse("/teamwork -p system_migration /goal Zero-downtime cutover")

      assert intent3.kind == :goal
      assert intent3.boost? == false
      assert intent3.teamwork? == true
      assert intent3.blueprint_pattern == "system_migration"
      assert intent3.objective == "Zero-downtime cutover"
    end

    test "parses standalone /teamwork with flags and direct objective" do
      assert {:ok, intent} =
               CommandParser.parse(
                 "/teamwork --pattern=self_verification --boost Run security audit"
               )

      assert intent.kind == :teamwork
      assert intent.boost? == true
      assert intent.teamwork? == true
      assert intent.blueprint_pattern == "self_verification"
      assert intent.objective == "Run security audit"
    end

    test "rejects legacy /teamwork-preview and --teamwork-preview" do
      assert_error("/teamwork-preview", :unknown_command, "/teamwork-preview")
      assert_error("/teamwork --teamwork-preview", :invalid_option, "/teamwork")
    end

    test "supports --teamwork flag in /boost command" do
      assert {:ok, intent} = CommandParser.parse("/boost --teamwork /goal Migrate legacy code")
      assert intent.kind == :goal
      assert intent.teamwork? == true
      assert intent.boost? == true
      assert intent.objective == "Migrate legacy code"
    end

    test "rejects empty objectives for boost and chained commands without objective" do
      assert_error("/boost", :missing_objective, "/boost")
      assert_error("/teamwork /boost", :missing_objective, "/boost")

      assert_error(
        "/teamwork --pattern root_cause_and_fix",
        :missing_objective,
        "/teamwork"
      )

      assert_error(
        "/teamwork --pattern invalid_pattern /goal Fix bug",
        :invalid_pattern,
        "/teamwork"
      )
    end
  end

  defp assert_error(input, code, command) do
    assert {:error, %CommandError{code: ^code, command: ^command}} = CommandParser.parse(input)
  end
end

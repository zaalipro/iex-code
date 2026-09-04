defmodule IexCode.LLM.SystemPromptBuilderTest do
  use ExUnit.Case, async: true
  alias IexCode.Settings.AppSettings
  alias IexCode.LLM.SystemPromptBuilder

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "iex_code_prompt_builder_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  describe "personas/0 and persona_description/1" do
    test "provides definitions for standard personas" do
      personas = SystemPromptBuilder.personas()
      assert Map.has_key?(personas, "pragmatic_engineer")
      assert Map.has_key?(personas, "architect")
      assert Map.has_key?(personas, "security_auditor")
      assert Map.has_key?(personas, "minimalist")

      assert SystemPromptBuilder.persona_description("architect") =~ "expert systems architect"
      assert SystemPromptBuilder.persona_description(:security_auditor) =~ "security auditor"
    end
  end

  describe "build/3" do
    test "builds minimal prompt with base role and default persona" do
      base = "You are a general coding assistant."
      prompt = SystemPromptBuilder.build(base, nil, nil)

      assert prompt =~ "You are a general coding assistant."
      assert prompt =~ "## Persona"
      assert prompt =~ "pragmatic, delivery-focused"
      assert prompt =~ "## Security & Execution Boundary"
    end

    test "injects custom persona preset" do
      settings = %AppSettings{workspace_persona: "architect"}
      prompt = SystemPromptBuilder.build("Base role", nil, settings)

      assert prompt =~ "## Persona"
      assert prompt =~ "expert systems architect"
    end

    test "injects custom instructions and coding style guidelines when set" do
      settings = %AppSettings{
        custom_system_prompt: "Always respond in concise markdown bullet points.",
        coding_style_rules: "Prefer Enum.reduce/3 over recursive functions."
      }

      prompt = SystemPromptBuilder.build("Base role", nil, settings)

      assert prompt =~ "## Custom Instructions"
      assert prompt =~ "Always respond in concise markdown bullet points."
      assert prompt =~ "## Coding Style Guidelines"
      assert prompt =~ "Prefer Enum.reduce/3 over recursive functions."
    end

    test "detects and appends AGENTS.md from project root", %{tmp_dir: tmp_dir} do
      agents_file = Path.join(tmp_dir, "AGENTS.md")
      File.write!(agents_file, "# Project Guidelines\n- Never edit files without reading.")

      prompt = SystemPromptBuilder.build("Base role", tmp_dir, %AppSettings{})

      assert prompt =~ "## Project Workspace Rules (AGENTS.md)"
      assert prompt =~ "Never edit files without reading."
    end

    test "detects CODEX.md when AGENTS.md is absent", %{tmp_dir: tmp_dir} do
      codex_file = Path.join(tmp_dir, "CODEX.md")
      File.write!(codex_file, "Follow strict TDD flow.")

      prompt = SystemPromptBuilder.build("Base role", tmp_dir, %AppSettings{})

      assert prompt =~ "## Project Workspace Rules (CODEX.md)"
      assert prompt =~ "Follow strict TDD flow."
    end

    test "handles missing or non-existent directory gracefully" do
      prompt = SystemPromptBuilder.build("Base role", "/non/existent/path", nil)
      refute prompt =~ "Project Workspace Rules"
    end
  end
end

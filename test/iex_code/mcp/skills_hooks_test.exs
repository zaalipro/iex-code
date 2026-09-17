defmodule IexCode.MCP.SkillsHooksTest do
  use ExUnit.Case, async: true

  alias IexCode.MCP.{Hooks, Skills}

  test "loads skills with frontmatter and fallbacks" do
    dir = Path.join(System.tmp_dir!(), "skills-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "review"))
    on_exit(fn -> File.rm_rf(dir) end)

    File.write!(
      Path.join([dir, "review", "SKILL.md"]),
      "---\nname: review\ndescription: Review diffs.\n---\n# Review\nDo it.\n"
    )

    File.write!(Path.join(dir, "SKILL.md"), "# Bare\nNo frontmatter.\n")

    assert [review, bare] = Skills.load([dir])
    assert review.name == "review"
    assert review.description == "Review diffs."
    assert review.body =~ "# Review"
    assert bare.body =~ "# Bare"
  end

  test "later dirs win and output is sorted" do
    base = Path.join(System.tmp_dir!(), "skills2-#{System.unique_integer([:positive])}")
    one = Path.join(base, "one")
    two = Path.join(base, "two")
    File.mkdir_p!(Path.join(one, "dup"))
    File.mkdir_p!(Path.join(two, "dup"))
    on_exit(fn -> File.rm_rf(base) end)

    File.write!(Path.join([one, "dup", "SKILL.md"]), "---\nname: dup\ndescription: one\n---\n")
    File.write!(Path.join([two, "dup", "SKILL.md"]), "---\nname: dup\ndescription: two\n---\n")

    assert [%{name: "dup", description: "two"}] = Skills.load([one, two])
    assert Skills.load(["/nope/missing"]) == []
  end

  test "prompt section renders entries" do
    assert Skills.prompt_section([]) == ""

    section =
      Skills.prompt_section([%{name: "r", description: "d", body: "", path: "/p/SKILL.md"}])

    assert section =~ "- r: d (/p/SKILL.md)"
  end

  test "dispatch runs mfa and shell handlers" do
    config = %{
      "pre_tool" => [
        {:mfa, {__MODULE__, :allow_hook, []}},
        {:shell, "echo '{\"decision\":\"allow\"}'"}
      ]
    }

    assert [ok: :allowed, ok: %{"decision" => "allow"}] =
             Hooks.dispatch("pre_tool", %{"tool" => "read_file"}, config)

    assert [] = Hooks.dispatch("post_tool", %{}, config)
  end

  test "gate denies on deny results and hook failures" do
    deny_config = %{"pre_tool" => [{:mfa, {__MODULE__, :deny_hook, []}}]}
    assert {:deny, "nope"} = Hooks.gate("pre_tool", %{}, deny_config)

    crash_config = %{"pre_tool" => [{:mfa, {__MODULE__, :missing_hook, []}}]}
    assert {:deny, _reason} = Hooks.gate("pre_tool", %{}, crash_config)

    shell_deny = %{"pre_tool" => [{:shell, "echo '{\"decision\":\"deny\",\"reason\":\"x\"}'"}]}
    assert {:deny, "x"} = Hooks.gate("pre_tool", %{}, shell_deny)

    assert :ok = Hooks.gate("pre_tool", %{}, %{})
  end

  test "events lists the six lifecycle hooks" do
    assert Hooks.events() == [
             "session_start",
             "pre_model",
             "post_model",
             "pre_tool",
             "post_tool",
             "session_end"
           ]
  end

  def allow_hook(_payload), do: :allowed
  def deny_hook(_payload), do: {:deny, "nope"}
end

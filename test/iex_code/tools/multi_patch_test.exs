defmodule IexCode.Tools.MultiPatchTest do
  use IexCode.DataCase, async: false
  alias IexCode.Tools.MultiPatch

  @tag :tmp_dir
  test "Tier 2: exact match replacement", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "test.ex")
    File.write!(path, "def hello, do: :world\n")

    patches = [
      %{path: "test.ex", target: ":world", replacement: ":universe"}
    ]

    assert {:ok, summary} = MultiPatch.apply_patches(tmp_dir, patches)
    assert summary.applied == 1
    assert summary.tiers_used.exact == 1
    assert File.read!(path) == "def hello, do: :universe\n"
    assert summary.diff =~ "-def hello, do: :world"
    assert summary.diff =~ "+def hello, do: :universe"
  end

  @tag :tmp_dir
  test "Tier 3: fuzzy match with indentation and spacing differences", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "indent.ex")
    # File has 4 spaces
    File.write!(path, "defmodule Foo do\n    def run do\n        :ok\n    end\nend\n")

    # Patch has 2 spaces
    patches = [
      %{
        path: "indent.ex",
        target: "  def run do\n    :ok\n  end",
        replacement: "  def run do\n    :modified\n  end"
      }
    ]

    assert {:ok, summary} = MultiPatch.apply_patches(tmp_dir, patches)
    assert summary.applied == 1
    assert summary.tiers_used.fuzzy == 1
    content = File.read!(path)
    assert content =~ ":modified"
    assert content =~ "    def run do"
  end

  @tag :tmp_dir
  test "Atomic Rollback: reverts all changes if any patch in batch fails", %{tmp_dir: tmp_dir} do
    f1 = Path.join(tmp_dir, "f1.ex")
    f2 = Path.join(tmp_dir, "f2.ex")
    File.write!(f1, "defmodule F1 do\n  def orig1, do: 1\nend\n")
    File.write!(f2, "defmodule F2 do\n  def orig2, do: 2\nend\n")

    patches = [
      %{path: "f1.ex", target: "orig1", replacement: "new1"},
      %{path: "f2.ex", target: "non_existent_target_symbol", replacement: "new2"}
    ]

    assert {:error, {:target_not_found, "f2.ex", _}} = MultiPatch.apply_patches(tmp_dir, patches)

    # f1 MUST NOT be modified
    assert File.read!(f1) == "defmodule F1 do\n  def orig1, do: 1\nend\n"
    assert File.read!(f2) == "defmodule F2 do\n  def orig2, do: 2\nend\n"
  end

  @tag :tmp_dir
  test "Syntax Error check prevents broken code from applying", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "syntax.ex")
    File.write!(path, "defmodule Syntax do\n  def ok, do: :ok\nend\n")

    patches = [
      %{path: "syntax.ex", target: "def ok, do: :ok", replacement: "def ok, do: ((("}
    ]

    assert {:error, {:syntax_error, "syntax.ex", _}} = MultiPatch.apply_patches(tmp_dir, patches)
    assert File.read!(path) =~ "def ok, do: :ok"
  end

  @tag :tmp_dir
  test "preview_patches/3 generates diff without writing to disk", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "preview.ex")
    File.write!(path, "def value, do: 100\n")

    patches = [
      %{path: "preview.ex", target: "100", replacement: "200"}
    ]

    assert {:ok, %{diff: diff, patches: planned}} = MultiPatch.preview_patches(tmp_dir, patches)
    assert length(planned) == 1
    assert diff =~ "-def value, do: 100"
    assert diff =~ "+def value, do: 200"

    # Disk remains unchanged
    assert File.read!(path) == "def value, do: 100\n"
  end

  @tag :tmp_dir
  test "rollback/1 restores previous state from snapshot", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "rollback.ex")
    File.write!(path, "defmodule Rollback do\n  def state, do: :v1\nend\n")

    patches = [
      %{path: "rollback.ex", target: ":v1", replacement: ":v2"}
    ]

    assert {:ok, summary} = MultiPatch.apply_patches(tmp_dir, patches)
    assert File.read!(path) =~ ":v2"

    assert {:ok, %{restored_files: ["rollback.ex"]}} = MultiPatch.rollback(summary.transaction_id)
    assert File.read!(path) =~ ":v1"
  end

  describe "ambiguity rejection, anchor disambiguation, and diagnostics" do
    alias IexCode.Tools.MultiPatch.Matcher

    test "Matcher.patch preserves legacy first-match exact behavior when reject_ambiguous is false" do
      content = """
      defmodule Sample do
        def status, do: :ok
        def other, do: :wait
        def second_status, do: :ok
      end
      """

      assert {:ok, %{content: patched, tier: :exact}} =
               Matcher.patch(content, "do: :ok", "do: :ready")

      assert patched =~ "def status, do: :ready"
      assert patched =~ "def second_status, do: :ok"
    end

    test "Matcher.patch rejects ambiguous exact matches when reject_ambiguous: true without falling back" do
      content = """
      defmodule Sample do
        def a, do: :ok
        def middle, do: :noop
        def b, do: :ok
      end
      """

      assert {:error, {:ambiguous_match, [2, 4]}} =
               Matcher.patch(content, "do: :ok", "do: :done", reject_ambiguous: true)
    end

    test "Matcher.patch disambiguates exact matches via 1-based anchor_line and rejects equidistant ties" do
      content = """
      line 1
      return :same
      line 3
      line 4
      line 5
      return :same
      line 7
      """

      assert {:ok, %{content: patched, tier: :exact}} =
               Matcher.patch(content, "return :same", "return :second",
                 reject_ambiguous: true,
                 anchor_line: 6
               )

      lines = String.split(patched, "\n")
      assert Enum.at(lines, 1) == "return :same"
      assert Enum.at(lines, 5) == "return :second"

      # Line 4 is equidistant (distance 2) from lines 2 and 6
      assert {:error, {:ambiguous_match, [2, 6]}} =
               Matcher.patch(content, "return :same", "return :tied",
                 reject_ambiguous: true,
                 anchor_line: 4
               )
    end

    test "Matcher.patch tier3 fuzzy disambiguation uses accurate 1-based line numbers" do
      content = """
      defmodule FuzzyAnchor do
        def first do
          value = 1
        end

        def second do
          value = 1
        end
      end
      """

      # Fuzzy target with extra spaces forces tier3, occurring at 1-based lines 3 and 7.
      # Line 4 is closer to line 3 (dist 1) than line 7 (dist 3).
      # Line 5 is equidistant (dist 2 from 3 and dist 2 from 7) — off-by-one 0-based bug
      # previously broke exact distance symmetry around line 5.
      assert {:ok, %{content: first_patched, tier: :fuzzy}} =
               Matcher.patch(content, "  value   =   1", "  value = 42",
                 reject_ambiguous: true,
                 anchor_line: 3
               )

      assert first_patched =~ "def first do\n    value = 42"
      assert first_patched =~ "def second do\n    value = 1"

      assert {:error, {:ambiguous_match, [3, 7]}} =
               Matcher.patch(content, "  value   =   1", "  value = 99",
                 reject_ambiguous: true,
                 anchor_line: 5
               )
    end

    test "Matcher.diagnose_failure reports duplicate lines and closest matching window" do
      content = """
      defmodule Diag do
        def alpha(x) do
          x + 1
        end

        def beta(y) do
          y + 2
        end
      end
      """

      dup_diag = Matcher.diagnose_failure(content <> "\n  x + 1\n", "x + 1")
      assert dup_diag =~ "lines 3, 11"

      miss_diag = Matcher.diagnose_failure(content, "def alpha(z) do\n  z + 99\nend")
      assert miss_diag =~ "Closest matching window"
      assert miss_diag =~ "2:   def alpha(x) do"
    end

    @tag :tmp_dir
    test "MultiPatch propagates ambiguous_target without partial writes and accepts anchor_line",
         %{
           tmp_dir: tmp_dir
         } do
      a_path = Path.join(tmp_dir, "a.ex")
      dup_path = Path.join(tmp_dir, "dup.ex")

      File.write!(a_path, "defmodule A do\n  def ok, do: 1\nend\n")

      File.write!(dup_path, """
      defmodule Dup do
        def one, do: :target
        def two, do: :other
        def three, do: :target
      end
      """)

      patches = [
        %{path: "a.ex", target: "do: 1", replacement: "do: 2"},
        %{path: "dup.ex", target: "do: :target", replacement: "do: :fixed"}
      ]

      assert {:error, {:ambiguous_target, "dup.ex", [2, 4]}} =
               MultiPatch.apply_patches(tmp_dir, patches)

      # Atomic: a.ex must remain untouched
      assert File.read!(a_path) =~ "do: 1"

      anchored_patches = [
        %{"path" => "a.ex", "target_content" => "do: 1", "replacement_content" => "do: 2"},
        %{
          "path" => "dup.ex",
          "target_content" => "do: :target",
          "replacement_content" => "do: :fixed",
          "anchor_line" => 4
        }
      ]

      assert {:ok, %{applied: 2}} = MultiPatch.apply_patches(tmp_dir, anchored_patches)
      assert File.read!(a_path) =~ "do: 2"
      dup_content = File.read!(dup_path)
      assert dup_content =~ "def one, do: :target"
      assert dup_content =~ "def three, do: :fixed"
    end
  end
end

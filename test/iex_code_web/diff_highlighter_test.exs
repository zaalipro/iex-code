defmodule IexCodeWeb.DiffHighlighterTest do
  use ExUnit.Case, async: true
  alias IexCode.Tools.Git.DiffParser.Line
  alias IexCodeWeb.DiffHighlighter, as: DH

  describe "tokenize/1 and split_tokens/1" do
    test "syntax tokenizer identifies Elixir keywords, modules, atoms, strings, and comments" do
      code = "defmodule Math do # calculate"
      tokens = DH.tokenize(code)
      assert {:keyword, "defmodule"} in tokens
      assert {:module, "Math"} in tokens
      assert {:keyword, "do"} in tokens
      assert {:comment, "# calculate"} in tokens
    end

    test "syntax tokenizer losslessly reconstructs source strings" do
      inputs = [
        "  def perform_work(arg, opts \\\\ []) do",
        "  # Note: @spec foo(integer()) :: {:ok, boolean()}",
        "\t\tx = a |> Enum.map(&(&1 * 2))",
        "emoji: 🚀 and unicode: café crème",
        "counts_valid? and run!",
        "  ",
        ""
      ]

      for input <- inputs do
        tokens = DH.tokenize(input)
        assert Enum.map_join(tokens, &elem(&1, 1)) == input
      end
    end

    test "word tokenizer losslessly reconstructs source strings" do
      inputs = [
        "  def perform_work(arg, opts \\\\ []) do",
        "  # Note: @spec foo(integer()) :: {:ok, boolean()}",
        "\t\tx = a |> Enum.map(&(&1 * 2))",
        "emoji: 🚀 and unicode: café crème",
        "counts_valid? and run!",
        "  ",
        ""
      ]

      for input <- inputs do
        tokens = DH.split_tokens(input)
        assert Enum.join(tokens) == input
        assert DH.tokenize(input, :words) == tokens
      end
    end

    test "splits punctuation into single tokens to preserve delimiters" do
      tokens = DH.split_tokens("foo(1)")
      assert tokens == ["foo", "(", "1", ")"]
    end

    test "handles empty and nil input" do
      assert DH.tokenize(nil) == []
      assert DH.tokenize("") == []
      assert DH.split_tokens(nil) == []
      assert DH.split_tokens("") == []
    end
  end

  describe "word_diff/3" do
    test "satisfies lossless reconstruction invariant" do
      old_line = "  def perform_work(%User{id: id, status: :active} = user, opts \\\\ []) do"

      new_line =
        "  def perform_work(%User{id: id, status: :verified} = user, opts \\\\ [timeout: 5000]) do"

      diff = DH.word_diff(old_line, new_line)

      del_recon =
        diff
        |> Enum.filter(fn {t, _} -> t in [:eq, :del] end)
        |> Enum.map_join(fn {_, s} -> s end)

      ins_recon =
        diff
        |> Enum.filter(fn {t, _} -> t in [:eq, :ins] end)
        |> Enum.map_join(fn {_, s} -> s end)

      assert del_recon == old_line
      assert ins_recon == new_line
    end

    test "highlights variable and identifier changes at word boundaries" do
      diff = DH.word_diff("user.first_name", "user.full_name")
      assert diff == [eq: "user.", del: "first_name", ins: "full_name"]
    end

    test "highlights argument additions within parentheses" do
      diff = DH.word_diff("def add(a, b)", "def add(a, b, c)")
      assert diff == [eq: "def add(a, b", ins: ", c", eq: ")"]
    end

    test "handles indentation and whitespace changes" do
      diff = DH.word_diff("  foo()", "    foo()")
      assert diff == [del: "  ", ins: "    ", eq: "foo()"]
    end

    test "handles identical lines" do
      assert DH.word_diff("  foo()", "  foo()") == [eq: "  foo()"]
      assert DH.word_diff("", "") == []
    end

    test "handles empty string and nil transitions" do
      assert DH.word_diff("", "hello") == [ins: "hello"]
      assert DH.word_diff("hello", "") == [del: "hello"]
      assert DH.word_diff(nil, "hello") == [ins: "hello"]
      assert DH.word_diff("hello", nil) == [del: "hello"]
      assert DH.word_diff(nil, nil) == []
    end

    test "prevents zebra-striping on completely different lines" do
      diff = DH.word_diff("import Config", "alias MyApp.Repo")
      assert diff == [del: "import Config", ins: "alias MyApp.Repo"]
    end

    test "bypasses Myers explosion on very long lines" do
      long1 = String.duplicate("a = 1; ", 400)
      long2 = String.duplicate("b = 2; ", 400)
      assert DH.word_diff(long1, long2) == [{:del, long1}, {:ins, long2}]
    end
  end

  describe "char_diff/2" do
    test "computes character-level differences" do
      diff = DH.char_diff("cat", "car")
      assert diff == [eq: "ca", del: "t", ins: "r"]
    end

    test "handles edge cases in char_diff" do
      assert DH.char_diff("same", "same") == [eq: "same"]
      assert DH.char_diff("", "") == []
      assert DH.char_diff(nil, "new") == [ins: "new"]
      assert DH.char_diff("old", nil) == [del: "old"]
    end
  end

  describe "line_segments/2" do
    test "extracts normal and highlighted segments for deletion lines" do
      diff = [eq: "def add(", del: "a, b", ins: "a, b, c", eq: ")"]
      segments = DH.line_segments(diff, :deletion)
      assert segments == [normal: "def add(", highlight: "a, b", normal: ")"]
      assert Enum.map_join(segments, &elem(&1, 1)) == "def add(a, b)"
    end

    test "extracts normal and highlighted segments for addition lines" do
      diff = [eq: "def add(", del: "a, b", ins: "a, b, c", eq: ")"]
      segments = DH.line_segments(diff, :addition)
      assert segments == [normal: "def add(", highlight: "a, b, c", normal: ")"]
      assert Enum.map_join(segments, &elem(&1, 1)) == "def add(a, b, c)"
    end

    test "extracts normal segment for context lines" do
      diff = [eq: "def add(a, b) do"]
      segments = DH.line_segments(diff, :context)
      assert segments == [normal: "def add(a, b) do"]
    end
  end

  describe "pair_split_lines/1 and pair_hunk_lines/1" do
    test "pairs balanced replacements (1 del, 1 add) without spacers" do
      lines = [
        %Line{type: :context, content: "start", old_num: 1, new_num: 1},
        %Line{type: :deletion, content: "old", old_num: 2, new_num: nil},
        %Line{type: :addition, content: "new", old_num: nil, new_num: 2},
        %Line{type: :context, content: "end", old_num: 3, new_num: 3}
      ]

      pairs = DH.pair_split_lines(lines)
      assert length(pairs) == 3
      assert [{l1, r1}, {l2, r2}, {l3, r3}] = pairs
      assert l1.content == "start" and r1.content == "start"
      assert l2.type == :deletion and r2.type == :addition
      assert l3.content == "end" and r3.content == "end"
    end

    test "pads right column with nil when deletions exceed additions in pair_split_lines" do
      lines = [
        %{type: :deletion, content: "del 1", old_num: 1, new_num: nil},
        %{type: :deletion, content: "del 2", old_num: 2, new_num: nil},
        %{type: :addition, content: "add 1", old_num: nil, new_num: 1},
        %{type: :context, content: "ctx 1", old_num: 3, new_num: 2}
      ]

      pairs = DH.pair_split_lines(lines)
      assert length(pairs) == 3
      assert {left0, right0} = Enum.at(pairs, 0)
      assert left0.type == :deletion and right0.type == :addition

      assert {left1, right1} = Enum.at(pairs, 1)
      assert left1.type == :deletion and is_nil(right1)

      assert {left2, right2} = Enum.at(pairs, 2)
      assert left2.type == :context and right2.type == :context
    end

    test "pads with :empty in pair_hunk_lines when deletions exceed additions" do
      lines = [
        %Line{type: :context, content: "start", old_num: 1, new_num: 1},
        %Line{type: :deletion, content: "del1", old_num: 2, new_num: nil},
        %Line{type: :deletion, content: "del2", old_num: 3, new_num: nil},
        %Line{type: :deletion, content: "del3", old_num: 4, new_num: nil},
        %Line{type: :addition, content: "add1", old_num: nil, new_num: 2},
        %Line{type: :context, content: "end", old_num: 5, new_num: 3}
      ]

      pairs = DH.pair_hunk_lines(lines)
      assert length(pairs) == 5

      # Context at index 0
      assert {c0_left, c0_right} = Enum.at(pairs, 0)
      assert c0_left.content == "start" and c0_right.content == "start"

      # Deletion 1 paired with Addition 1
      assert {l1, r1} = Enum.at(pairs, 1)
      assert l1.content == "del1" and r1.content == "add1"

      # Deletions 2 and 3 paired with :empty
      assert {l2, :empty} = Enum.at(pairs, 2)
      assert l2.content == "del2"
      assert {l3, :empty} = Enum.at(pairs, 3)
      assert l3.content == "del3"

      # Final context line perfectly aligned at index 4 (0 vertical drift)
      assert {l4, r4} = Enum.at(pairs, 4)
      assert l4.content == "end" and r4.content == "end"
    end

    test "pads left column with :empty when additions exceed deletions" do
      lines = [
        %Line{type: :context, content: "start", old_num: 1, new_num: 1},
        %Line{type: :deletion, content: "del1", old_num: 2, new_num: nil},
        %Line{type: :addition, content: "add1", old_num: nil, new_num: 2},
        %Line{type: :addition, content: "add2", old_num: nil, new_num: 3},
        %Line{type: :context, content: "end", old_num: 3, new_num: 4}
      ]

      pairs = DH.pair_hunk_lines(lines)
      assert length(pairs) == 4
      assert {:empty, r2} = Enum.at(pairs, 2)
      assert r2.content == "add2"
      assert {l3, r3} = Enum.at(pairs, 3)
      assert l3.content == "end" and r3.content == "end"
    end

    test "handles addition-only and deletion-only hunks" do
      adds = [
        %Line{type: :addition, content: "a1", old_num: nil, new_num: 1},
        %Line{type: :addition, content: "a2", old_num: nil, new_num: 2}
      ]

      assert [{:empty, a1}, {:empty, a2}] = DH.pair_hunk_lines(adds)
      assert a1.content == "a1" and a2.content == "a2"

      dels = [
        %Line{type: :deletion, content: "d1", old_num: 1, new_num: nil}
      ]

      assert [{d1, :empty}] = DH.pair_hunk_lines(dels)
      assert d1.content == "d1"
    end

    test "handles empty lines input" do
      assert DH.pair_split_lines([]) == []
      assert DH.pair_split_lines(nil) == []
      assert DH.pair_hunk_lines([]) == []
      assert DH.pair_hunk_lines(nil) == []
    end
  end

  describe "prepare_inline_lines/1" do
    test "pairs deletion and addition in change block to compute word highlights" do
      lines = [
        %Line{type: :context, content: "def calc do", old_num: 1, new_num: 1},
        %Line{type: :deletion, content: "  user.first_name", old_num: 2, new_num: nil},
        %Line{type: :addition, content: "  user.full_name", old_num: nil, new_num: 2},
        %Line{type: :context, content: "end", old_num: 3, new_num: 3}
      ]

      prepared = DH.prepare_inline_lines(lines)
      assert length(prepared) == 4

      # Context 1
      assert %{line: %{type: :context}, segments: [{:normal, "def calc do"}]} =
               Enum.at(prepared, 0)

      # Deletion line has word highlight for "first_name"
      %{line: %{type: :deletion}, segments: del_segs} = Enum.at(prepared, 1)
      assert {:highlight, "first_name"} in del_segs
      assert {:normal, "  user."} in del_segs

      # Addition line has word highlight for "full_name"
      %{line: %{type: :addition}, segments: add_segs} = Enum.at(prepared, 2)
      assert {:highlight, "full_name"} in add_segs
      assert {:normal, "  user."} in add_segs

      # Context 2
      assert %{line: %{type: :context}, segments: [{:normal, "end"}]} = Enum.at(prepared, 3)
    end
  end
end

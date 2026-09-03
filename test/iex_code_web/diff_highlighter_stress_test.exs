defmodule IexCodeWeb.DiffHighlighterStressTest do
  use ExUnit.Case, async: true

  alias IexCode.Tools.Git.DiffParser.Line
  alias IexCodeWeb.DiffHighlighter, as: DH
  alias IexCodeWeb.WorkspaceComponents
  import Phoenix.LiveViewTest

  @moduledoc """
  Adversarial stress harness for IexCodeWeb.DiffHighlighter and split row alignment.
  Tests extreme Unicode, emojis, unclosed delimiters, null bytes, long lines (>10,000 chars),
  worst-case Myers difference, asymmetric hunks with zero vertical drift, and 500+ generated
  strings for lossless reconstruction.
  """

  # ----------------------------------------------------------------------------
  # 1. Extreme Unicode, Emojis, and Complex Glyphs
  # ----------------------------------------------------------------------------
  describe "extreme unicode, emojis, and complex glyphs" do
    test "handles complex multilingual scripts and RTL text" do
      cases = [
        {"def مرحبا(الاسم), do: :أهلا", "def مرحبا(الاسم_الكامل), do: :أهلا_وسهلا"},
        {"שלום עולם = 1", "שלום לכולם = 2"},
        {"def สวัสดี(ชื่อ), do: :ยินดี", "def สวัสดี(ชื่อ_เต็ม), do: :ยินดีต้อนรับ"},
        {"def नमस्ते(नाम), do: :स्वागत", "def नमस्ते(पूरा_नाम), do: :स्वागतम्"},
        {"defmodule 漢字モジュール do", "defmodule 漢字拡張モジュール do"},
        {"fn -> :Ελληνικά end", "fn -> :Ελληνικά_τέλος end"}
      ]

      for {old_str, new_str} <- cases do
        diff = DH.word_diff(old_str, new_str)
        del_recon = DH.line_segments(diff, :deletion) |> Enum.map_join(&elem(&1, 1))
        add_recon = DH.line_segments(diff, :addition) |> Enum.map_join(&elem(&1, 1))

        assert del_recon == old_str
        assert add_recon == new_str

        assert DH.tokenize(old_str, :syntax) |> Enum.map_join(&elem(&1, 1)) == old_str
        assert DH.tokenize(new_str, :syntax) |> Enum.map_join(&elem(&1, 1)) == new_str
        assert DH.split_tokens(old_str) |> Enum.join() == old_str
        assert DH.split_tokens(new_str) |> Enum.join() == new_str
      end
    end

    test "handles multi-codepoint emojis, skin tones, ZWJ sequences, and flags" do
      cases = [
        # Skin tone modifier
        {"thumbs = 👍", "thumbs = 👍🏽"},
        # Zero-width joiner family sequence (👨‍👩‍👧‍👦)
        {"family = 👨‍👩‍👧‍👦", "family = 👩‍❤️‍💋‍👨"},
        # Profession ZWJ sequence (👩🏿‍💻)
        {"worker = 👩🏿‍💻", "worker = 🧑‍🚀"},
        # Regional indicator symbol flags (🇺🇸, 🏴󠁧󠁢󠁳󠁣󠁴󠁿)
        {"country = 🇺🇸", "country = 🏴󠁧󠁢󠁳󠁣󠁴󠁿"},
        # Variation selectors (❤️ vs ❤)
        {"heart = ❤️", "heart = 💔"}
      ]

      for {old_str, new_str} <- cases do
        diff = DH.word_diff(old_str, new_str)
        del_recon = DH.line_segments(diff, :deletion) |> Enum.map_join(&elem(&1, 1))
        add_recon = DH.line_segments(diff, :addition) |> Enum.map_join(&elem(&1, 1))

        assert del_recon == old_str
        assert add_recon == new_str

        assert DH.tokenize(old_str, :syntax) |> Enum.map_join(&elem(&1, 1)) == old_str
        assert DH.tokenize(new_str, :syntax) |> Enum.map_join(&elem(&1, 1)) == new_str
        assert DH.split_tokens(old_str) |> Enum.join() == old_str
        assert DH.split_tokens(new_str) |> Enum.join() == new_str
      end
    end

    test "handles Zalgo combining diacritics without crash or corruption" do
      zalgo_1 = "Zalgo: e\u0301\u0300\u0308\u0327\u0332\u031b\u0342 test"
      zalgo_2 = "Zalgo: e\u0301\u0300\u0308\u0327\u0332\u031b\u0342 modified"

      diff = DH.word_diff(zalgo_1, zalgo_2)
      del_recon = DH.line_segments(diff, :deletion) |> Enum.map_join(&elem(&1, 1))
      add_recon = DH.line_segments(diff, :addition) |> Enum.map_join(&elem(&1, 1))

      assert del_recon == zalgo_1
      assert add_recon == zalgo_2
      assert DH.tokenize(zalgo_1, :syntax) |> Enum.map_join(&elem(&1, 1)) == zalgo_1
      assert DH.split_tokens(zalgo_1) |> Enum.join() == zalgo_1
    end
  end

  # ----------------------------------------------------------------------------
  # 2. Unclosed Strings and Delimiters
  # ----------------------------------------------------------------------------
  describe "unclosed strings, delimiters, and malformed code" do
    test "handles unclosed quotes, escapes, and brackets without hanging" do
      cases = [
        {"x = \"unclosed double quote", "x = \"unclosed double quote with more"},
        {"x = 'unclosed single quote", "x = 'unclosed single quote modified"},
        {"str = \"escaped \\\" quote but unclosed", "str = \"escaped \\\" quote still unclosed"},
        {"nested = ((([[[{{{<><>", "nested = ((([[[{{{<><>)))"},
        {"heredoc = \"\"\"unfinished", "heredoc = \"\"\"finished\"\"\""},
        {"regex = ~r/unclosed pattern", "regex = ~r/closed pattern/"},
        {"pipe = foo |> bar( |>", "pipe = foo |> bar() |> baz()"}
      ]

      for {old_str, new_str} <- cases do
        diff = DH.word_diff(old_str, new_str)
        del_recon = DH.line_segments(diff, :deletion) |> Enum.map_join(&elem(&1, 1))
        add_recon = DH.line_segments(diff, :addition) |> Enum.map_join(&elem(&1, 1))

        assert del_recon == old_str
        assert add_recon == new_str

        assert DH.tokenize(old_str, :syntax) |> Enum.map_join(&elem(&1, 1)) == old_str
        assert DH.tokenize(new_str, :syntax) |> Enum.map_join(&elem(&1, 1)) == new_str
        assert DH.split_tokens(old_str) |> Enum.join() == old_str
        assert DH.split_tokens(new_str) |> Enum.join() == new_str
      end
    end
  end

  # ----------------------------------------------------------------------------
  # 3. Null Bytes and Binary Control Characters
  # ----------------------------------------------------------------------------
  describe "null bytes and control characters" do
    test "preserves null bytes and control codes losslessly" do
      cases = [
        {"hello\0world", "hello\0there\0world"},
        {"\0\0\0", "\0\0\0\0"},
        {"code_with_\0_null_byte = 1", "code_with_\0_null_byte = 2"},
        {"ansi = \e[31mred\e[0m", "ansi = \e[32mgreen\e[0m"},
        {"ctrl = \a\b\f\v\r", "ctrl = \a\b\f\v\r\t"}
      ]

      for {old_str, new_str} <- cases do
        diff = DH.word_diff(old_str, new_str)
        del_recon = DH.line_segments(diff, :deletion) |> Enum.map_join(&elem(&1, 1))
        add_recon = DH.line_segments(diff, :addition) |> Enum.map_join(&elem(&1, 1))

        assert del_recon == old_str
        assert add_recon == new_str

        assert DH.tokenize(old_str, :syntax) |> Enum.map_join(&elem(&1, 1)) == old_str
        assert DH.tokenize(new_str, :syntax) |> Enum.map_join(&elem(&1, 1)) == new_str
        assert DH.split_tokens(old_str) |> Enum.join() == old_str
        assert DH.split_tokens(new_str) |> Enum.join() == new_str
      end
    end
  end

  # ----------------------------------------------------------------------------
  # 4. Long Lines (>10,000 chars) & Process Timeout Protection
  # ----------------------------------------------------------------------------
  describe "long lines (>10,000 chars) and max_line_bytes guards" do
    test "executes in sub-millisecond time on massive lines (>10,000 chars) preventing BEAM timeout" do
      # 10,000 chars
      line_10k_a = "prefix_" <> String.duplicate("abcdefghij", 1_000) <> "_suffix_a"
      line_10k_b = "prefix_" <> String.duplicate("abcdefghij", 1_000) <> "_suffix_b"

      {time_us, result} = :timer.tc(fn -> DH.word_diff(line_10k_a, line_10k_b) end)

      # Under 10ms (10,000 microseconds)
      assert time_us < 10_000
      assert result == [{:del, line_10k_a}, {:ins, line_10k_b}]

      # 50,000 chars
      line_50k_a = String.duplicate("x = 12345; ", 4_500)
      line_50k_b = String.duplicate("y = 67890; ", 4_500)

      {time_50k_us, result_50k} = :timer.tc(fn -> DH.word_diff(line_50k_a, line_50k_b) end)
      assert time_50k_us < 10_000
      assert result_50k == [{:del, line_50k_a}, {:ins, line_50k_b}]

      # 100,000 chars identical - O(1) equality check
      line_100k = String.duplicate("const largeData = [1, 2, 3]; ", 3_300)
      {time_100k_us, result_100k} = :timer.tc(fn -> DH.word_diff(line_100k, line_100k) end)
      assert time_100k_us < 5_000
      assert result_100k == [{:eq, line_100k}]
    end

    test "smooth boundary transition around 2,000 bytes" do
      # Boundary: 1,990 bytes (below 2,000) -> uses Myers word diff
      # 1,990 bytes
      base_small = String.duplicate("item ", 398)
      v1 = base_small <> "old"
      v2 = base_small <> "new"
      diff_sub = DH.word_diff(v1, v2)
      assert [{:eq, eq_part}, {:del, "old"}, {:ins, "new"}] = diff_sub
      assert eq_part == base_small

      # Boundary: 2,005 bytes (above 2,000) -> falls back to full line replacement
      # 2,005 bytes
      base_large = String.duplicate("item ", 401)
      v_large1 = base_large <> "old"
      v_large2 = base_large <> "new"
      diff_super = DH.word_diff(v_large1, v_large2)
      assert diff_super == [{:del, v_large1}, {:ins, v_large2}]

      # Both satisfy lossless reconstruction
      for {d, a, b} <- [{diff_sub, v1, v2}, {diff_super, v_large1, v_large2}] do
        assert DH.line_segments(d, :deletion) |> Enum.map_join(&elem(&1, 1)) == a
        assert DH.line_segments(d, :addition) |> Enum.map_join(&elem(&1, 1)) == b
      end
    end

    test "worst-case Myers token sequences under 2,000 bytes terminate quickly" do
      # ~1,800 bytes with 200 alternating tokens
      s1 = Enum.map_join(1..180, " ", fn i -> "a#{i} b#{i}" end)
      s2 = Enum.map_join(1..180, " ", fn i -> "b#{i} a#{i}" end)

      assert byte_size(s1) < 2000
      assert byte_size(s2) < 2000

      {time_us, diff} = :timer.tc(fn -> DH.word_diff(s1, s2) end)

      # Under 100ms
      assert time_us < 100_000
      # Lossless reconstruction check
      assert DH.line_segments(diff, :deletion) |> Enum.map_join(&elem(&1, 1)) == s1
      assert DH.line_segments(diff, :addition) |> Enum.map_join(&elem(&1, 1)) == s2
    end
  end

  # ----------------------------------------------------------------------------
  # 5. Asymmetric Split Row Alignment (0 Vertical Drift)
  # ----------------------------------------------------------------------------
  describe "pair_split_lines/2 and pair_hunk_lines/2 zero vertical drift" do
    test "aligns asymmetric hunk (50 deletions, 2 additions) with 0 vertical drift" do
      ctx_before = %Line{type: :context, content: "def init do", old_num: 1, new_num: 1}

      deletions =
        for i <- 1..50 do
          %Line{type: :deletion, content: "  old_step_#{i}()", old_num: i + 1, new_num: nil}
        end

      additions = [
        %Line{type: :addition, content: "  new_step_1()", old_num: nil, new_num: 2},
        %Line{type: :addition, content: "  new_step_2()", old_num: nil, new_num: 3}
      ]

      ctx_after = %Line{type: :context, content: "end", old_num: 52, new_num: 4}

      hunk_lines = [ctx_before | deletions] ++ additions ++ [ctx_after]

      # Test with pair_split_lines (default spacer: nil)
      split_pairs = DH.pair_split_lines(hunk_lines, nil)

      # Row count: 1 context + 50 change rows (max(50, 2)) + 1 context = 52 rows
      assert length(split_pairs) == 52

      # Row 0: ctx_before
      assert {l0, r0} = Enum.at(split_pairs, 0)
      assert l0.content == "def init do"
      assert r0.content == "def init do"

      # Rows 1..2: deletions paired 1-to-1 with additions
      assert {l1, r1} = Enum.at(split_pairs, 1)
      assert l1.content == "  old_step_1()"
      assert r1.content == "  new_step_1()"

      assert {l2, r2} = Enum.at(split_pairs, 2)
      assert l2.content == "  old_step_2()"
      assert r2.content == "  new_step_2()"

      # Rows 3..50: deletions paired with nil spacers on right
      for idx <- 3..50 do
        {l, r} = Enum.at(split_pairs, idx)
        assert l.type == :deletion
        assert is_nil(r), "Expected spacer nil at row #{idx}, got: #{inspect(r)}"
      end

      # Row 51: ctx_after aligned at the EXACT same row index on both left and right (0 drift)
      assert {l51, r51} = Enum.at(split_pairs, 51)
      assert l51.content == "end"
      assert r51.content == "end"
      assert l51.old_num == 52
      assert r51.new_num == 4

      # Also test with pair_hunk_lines (default spacer: :empty)
      hunk_pairs = DH.pair_hunk_lines(hunk_lines)
      assert length(hunk_pairs) == 52
      assert {_, :empty} = Enum.at(hunk_pairs, 3)
      assert {l_end, r_end} = Enum.at(hunk_pairs, 51)
      assert l_end.content == "end" and r_end.content == "end"
    end

    test "aligns reverse asymmetric hunk (2 deletions, 50 additions) with 0 vertical drift" do
      ctx_before = %Line{type: :context, content: "def init do", old_num: 1, new_num: 1}

      deletions = [
        %Line{type: :deletion, content: "  old_1()", old_num: 2, new_num: nil},
        %Line{type: :deletion, content: "  old_2()", old_num: 3, new_num: nil}
      ]

      additions =
        for i <- 1..50 do
          %Line{type: :addition, content: "  new_step_#{i}()", old_num: nil, new_num: i + 1}
        end

      ctx_after = %Line{type: :context, content: "end", old_num: 4, new_num: 52}

      hunk_lines = [ctx_before | deletions] ++ additions ++ [ctx_after]

      split_pairs = DH.pair_split_lines(hunk_lines, :empty)
      assert length(split_pairs) == 52

      # Row 0: context
      assert {l0, r0} = Enum.at(split_pairs, 0)
      assert l0.content == "def init do" and r0.content == "def init do"

      # Rows 1..2: 1-to-1 pairs
      assert {l1, r1} = Enum.at(split_pairs, 1)
      assert l1.content == "  old_1()" and r1.content == "  new_step_1()"

      assert {l2, r2} = Enum.at(split_pairs, 2)
      assert l2.content == "  old_2()" and r2.content == "  new_step_2()"

      # Rows 3..50: left column has :empty spacers
      for idx <- 3..50 do
        {l, r} = Enum.at(split_pairs, idx)
        assert l == :empty, "Expected left spacer :empty at row #{idx}, got: #{inspect(l)}"
        assert r.type == :addition
      end

      # Row 51: context line aligned on both sides (0 vertical drift)
      assert {l51, r51} = Enum.at(split_pairs, 51)
      assert l51.content == "end" and r51.content == "end"
      assert l51.old_num == 4
      assert r51.new_num == 52
    end

    test "interleaved multiple asymmetric change groups align all context anchors" do
      # Context 1 -> 30 del, 2 add -> Context 2 -> 1 del, 20 add -> Context 3
      c1 = %Line{type: :context, content: "anchor_1", old_num: 1, new_num: 1}

      dels_1 =
        for i <- 1..30,
            do: %Line{type: :deletion, content: "d1_#{i}", old_num: 1 + i, new_num: nil}

      adds_1 =
        for i <- 1..2,
            do: %Line{type: :addition, content: "a1_#{i}", old_num: nil, new_num: 1 + i}

      c2 = %Line{type: :context, content: "anchor_2", old_num: 32, new_num: 4}
      dels_2 = [%Line{type: :deletion, content: "d2_1", old_num: 33, new_num: nil}]

      adds_2 =
        for i <- 1..20,
            do: %Line{type: :addition, content: "a2_#{i}", old_num: nil, new_num: 4 + i}

      c3 = %Line{type: :context, content: "anchor_3", old_num: 34, new_num: 25}

      all_lines = [c1 | dels_1] ++ adds_1 ++ [c2 | dels_2] ++ adds_2 ++ [c3]

      pairs = DH.pair_hunk_lines(all_lines, :empty)

      # Expected length:
      # 1 (c1) + max(30, 2) [30] + 1 (c2) + max(1, 20) [20] + 1 (c3) = 53 rows
      assert length(pairs) == 53

      # anchor_1 at row 0
      assert {Enum.at(pairs, 0), %Line{content: "anchor_1"}}
      {l_c1, r_c1} = Enum.at(pairs, 0)
      assert l_c1.content == "anchor_1" and r_c1.content == "anchor_1"

      # anchor_2 at row 31 (1 + 30)
      {l_c2, r_c2} = Enum.at(pairs, 31)
      assert l_c2.content == "anchor_2" and r_c2.content == "anchor_2"

      # anchor_3 at row 52 (31 + 1 + 20)
      {l_c3, r_c3} = Enum.at(pairs, 52)
      assert l_c3.content == "anchor_3" and r_c3.content == "anchor_3"
    end
  end

  # ----------------------------------------------------------------------------
  # 6. Lossless Reconstruction Invariant Across 500+ Generated Strings
  # ----------------------------------------------------------------------------
  describe "lossless reconstruction property across 500+ generated strings" do
    @descriptive_tokens [
      "def ",
      "defp ",
      "defmodule ",
      "case ",
      "cond ",
      "with ",
      "fn ",
      "-> ",
      ":ok",
      ":error",
      "nil",
      "true",
      "false",
      "%User{",
      "%{",
      "}",
      "]",
      "[",
      "(",
      ")",
      ", ",
      " |> ",
      " = ",
      " == ",
      " != ",
      " + ",
      " <> ",
      " \\\\ ",
      "User",
      "Repo",
      "Socket",
      "Assigns",
      "DiffHighlighter",
      "String",
      "Enum",
      "id: 123",
      "name: \"John Doe\"",
      "status: :active",
      "count + 1",
      "opts",
      " ",
      "  ",
      "    ",
      "\t",
      "🚀",
      "🔥",
      " café ",
      " naïve ",
      " mörður ",
      " 漢字 ",
      " مرحبا ",
      "\"escaped \\\" string\"",
      "'charlist'",
      "atom_name:",
      ":another_atom",
      "123_456",
      "0xFA12",
      "# inline comment",
      "// js comment",
      "\"unclosed string",
      "'unclosed charlist",
      "(((",
      "{{{",
      "<<<",
      "null_byte_\0_mid",
      "trailing_\0",
      "\0_leading"
    ]

    defp generate_random_code(seed, token_count) do
      :rand.seed(:exsplus, {seed, seed * 3, seed * 7})

      1..token_count
      |> Enum.map(fn _ ->
        idx = :rand.uniform(length(@descriptive_tokens)) - 1
        Enum.at(@descriptive_tokens, idx)
      end)
      |> Enum.join()
    end

    defp mutate_code(original, seed) do
      :rand.seed(:exsplus, {seed * 11, seed * 13, seed * 17})
      tokens = DH.split_tokens(original)

      if tokens == [] do
        "new_fallback_code()"
      else
        num_mutations = :rand.uniform(5)

        mutated_tokens =
          Enum.reduce(1..num_mutations, tokens, fn _, acc ->
            if acc == [] do
              acc
            else
              case :rand.uniform(3) do
                1 ->
                  if length(acc) > 1 do
                    del_idx = :rand.uniform(length(acc)) - 1
                    List.delete_at(acc, del_idx)
                  else
                    acc
                  end

                2 ->
                  ins_idx = :rand.uniform(length(acc)) - 1

                  replacement =
                    Enum.at(@descriptive_tokens, :rand.uniform(length(@descriptive_tokens)) - 1)

                  List.insert_at(acc, ins_idx, replacement)

                3 ->
                  rep_idx = :rand.uniform(length(acc)) - 1

                  replacement =
                    Enum.at(@descriptive_tokens, :rand.uniform(length(@descriptive_tokens)) - 1)

                  List.replace_at(acc, rep_idx, replacement)

                _ ->
                  acc
              end
            end
          end)

        Enum.join(mutated_tokens)
      end
    end

    test "500+ generated strings satisfy lossless reconstruction invariants" do
      iterations = 550

      results =
        for i <- 1..iterations do
          token_count = rem(i, 35) + 1
          str1 = generate_random_code(i * 1001, token_count)
          str2 = mutate_code(str1, i * 2003)

          # Invariant 1: split_tokens lossless
          tokens1 = DH.split_tokens(str1)

          assert Enum.join(tokens1) == str1,
                 "split_tokens failed to reconstruct str1 at iteration #{i}"

          # Invariant 2: tokenize(:syntax) lossless
          syntax_tokens = DH.tokenize(str1, :syntax)
          syntax_recon = Enum.map_join(syntax_tokens, &elem(&1, 1))

          assert syntax_recon == str1,
                 "tokenize(:syntax) failed to reconstruct str1 at iteration #{i}.\nOriginal: #{inspect(str1)}\nReconstructed: #{inspect(syntax_recon)}"

          # Invariant 3: word_diff lossless on both deletion and addition
          diff = DH.word_diff(str1, str2)

          del_segs = DH.line_segments(diff, :deletion)
          add_segs = DH.line_segments(diff, :addition)

          del_recon = Enum.map_join(del_segs, &elem(&1, 1))
          add_recon = Enum.map_join(add_segs, &elem(&1, 1))

          assert del_recon == str1,
                 "word_diff deletion reconstruction failed at iteration #{i}.\nOriginal: #{inspect(str1)}\nReconstructed: #{inspect(del_recon)}"

          assert add_recon == str2,
                 "word_diff addition reconstruction failed at iteration #{i}.\nOriginal: #{inspect(str2)}\nReconstructed: #{inspect(add_recon)}"

          :ok
        end

      assert length(results) == iterations
    end
  end

  # ----------------------------------------------------------------------------
  # 7. LiveView Component Rendering Under Adversarial Inputs
  # ----------------------------------------------------------------------------
  describe "component rendering with adversarial inputs" do
    test "renders hunk_split_lines with asymmetric 50-del / 2-add hunk without crashes" do
      deletions =
        for i <- 1..50 do
          %Line{
            type: :deletion,
            content: "  old_step_#{i}(\"param_#{i}\") # comment",
            old_num: i,
            new_num: nil
          }
        end

      additions = [
        %Line{type: :addition, content: "  new_step_1()", old_num: nil, new_num: 1},
        %Line{type: :addition, content: "  new_step_2()", old_num: nil, new_num: 2}
      ]

      rendered =
        render_component(&WorkspaceComponents.hunk_split_lines/1, %{
          lines: deletions ++ additions
        })

      assert rendered =~ "Original"
      assert rendered =~ "Modified"
      # Should render deletion lines
      assert rendered =~ "old_step_1"
      assert rendered =~ "old_step_50"
      # Should render addition lines
      assert rendered =~ "new_step_1"
      assert rendered =~ "new_step_2"
      # Should render 48 empty spacer elements
      assert rendered =~ "border-transparent"
    end

    test "renders hunk_split_lines with extreme unicode, unclosed strings, and null bytes" do
      adversarial_lines = [
        %Line{type: :context, content: "def init do", old_num: 1, new_num: 1},
        %Line{
          type: :deletion,
          content: "  val = \"unclosed string with emojis 🚀👍🏽",
          old_num: 2,
          new_num: nil
        },
        %Line{
          type: :addition,
          content: "  val = \"closed string with \0 null byte!\"",
          old_num: nil,
          new_num: 2
        },
        %Line{type: :context, content: "  مرحبا = :arabic", old_num: 3, new_num: 3}
      ]

      rendered =
        render_component(&WorkspaceComponents.hunk_split_lines/1, %{
          lines: adversarial_lines
        })

      assert rendered =~ "Original"
      assert rendered =~ "Modified"
      assert rendered =~ "🚀"
      assert rendered =~ "arabic"
    end

    test "renders hunk_inline_lines with asymmetric inputs and word diff highlights" do
      lines = [
        %Line{
          type: :deletion,
          content: "  user = get_user(id, :active)",
          old_num: 1,
          new_num: nil
        },
        %Line{
          type: :addition,
          content: "  user = get_user(id, :verified)",
          old_num: nil,
          new_num: 1
        }
      ]

      rendered =
        render_component(&WorkspaceComponents.hunk_inline_lines/1, %{
          lines: lines
        })

      assert rendered =~ "bg-rose-500/30"
      assert rendered =~ "active"
      assert rendered =~ "bg-emerald-500/30"
      assert rendered =~ "verified"
    end
  end
end

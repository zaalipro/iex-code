defmodule IexCode.Tools.BoundedFileToolsTest do
  use ExUnit.Case, async: false

  alias IexCode.Tools

  @moduletag :tmp_dir

  test "ordinary reads preserve newline, range and Unicode behavior", %{tmp_dir: root} do
    for {name, content, expected} <- [
          {"empty", "", "1: "},
          {"lf", "one\ntwo\n", "1: one\n2: two\n3: "},
          {"crlf", "one\r\ntwo", "1: one\n2: two"},
          {"unicode", "héllo\n世界", "1: héllo\n2: 世界"}
        ] do
      File.write!(Path.join(root, name), content)
      assert {:ok, ^expected} = read(root, name)
    end

    assert {:ok, "2: two\n3: "} = read(root, "lf", %{"start_line" => 2})
    assert {:ok, "1: one\n2: two"} = read(root, "lf", %{"start_line" => 1, "end_line" => 2})
    assert {:ok, ""} = read(root, "lf", %{"start_line" => 20})
    assert {:ok, "0: one\n1: two"} = read(root, "lf", %{"start_line" => 0, "end_line" => 1})
    assert {:error, missing} = read(root, "missing")
    assert missing =~ "File does not exist"
    assert {:error, unreadable} = read(root, ".")
    assert unreadable =~ "Failed to read file"
  end

  test "read removes only the CR belonging to a CRLF delimiter", %{tmp_dir: root} do
    File.write!(Path.join(root, "cr"), "one\r\r\ntwo\r")
    assert {:ok, "1: one\r\n2: two\r"} = read(root, "cr")
  end

  test "reads preserve split Unicode and CRLF at chunk boundaries", %{tmp_dir: root} do
    File.write!(Path.join(root, "split"), String.duplicate("a", 16_383) <> "界\r\nnext")
    assert {:ok, output} = read(root, "split")
    assert String.valid?(output)
    assert output =~ "界\n2: next"

    File.write!(Path.join(root, "crlf"), String.duplicate("a", 16_383) <> "\r\nnext")
    assert {:ok, output} = read(root, "crlf")
    refute output =~ "\r"
    assert output =~ "\n2: next"
  end

  test "reads bound giant lines and explicit range output at two file sizes", %{tmp_dir: root} do
    for size <- [8_000_000, 16_000_000] do
      File.write!(Path.join(root, "giant"), String.duplicate("x", size))
      assert {:ok, output} = read(root, "giant", %{"start_line" => 1, "end_line" => 1})
      assert byte_size(output) < 270_000
      assert output =~ "incomplete"
      assert output =~ "line"
      assert output =~ "narrow"
      refute output =~ "of 1 lines"

      File.write!(
        Path.join(root, "many"),
        String.duplicate(String.duplicate("x", 1_000) <> "\n", div(size, 1_001))
      )

      assert {:ok, output} = read(root, "many", %{"start_line" => 1})
      assert byte_size(output) < 270_000
      assert output =~ "incomplete"
    end
  end

  test "default line and scan ceilings report lower bounds instead of exact totals", %{
    tmp_dir: root
  } do
    File.write!(Path.join(root, "many"), String.duplicate("line\n", 2_000))
    assert {:ok, output} = read(root, "many")
    assert output =~ "800: line"
    refute output =~ "801: line"
    assert output =~ "incomplete"
    refute output =~ "of 2001 lines"

    File.write!(
      Path.join(root, "far"),
      String.duplicate(String.duplicate("x", 1_000) <> "\n", 5_000) <> "TAIL"
    )

    assert {:ok, output} = read(root, "far", %{"start_line" => 5_001, "end_line" => 5_001})
    assert output =~ "incomplete"
    assert output =~ "scan"
    refute output =~ "TAIL"
  end

  test "ordinary grep retains regex, fallback, case, trimming and candidate skips", %{
    tmp_dir: root
  } do
    File.write!(Path.join(root, "a.txt"), "  HéLLo  \r\nhello[\nworld\n")
    File.write!(Path.join(root, "invalid.txt"), "hello\n" <> <<255>>)
    File.ln_s!("missing", Path.join(root, "broken.txt"))
    assert {:ok, "a.txt:1: HéLLo\na.txt:2: hello["} = grep(root, "h.*llo")
    assert {:ok, "a.txt:2: hello["} = grep(root, "hello", %{"case_sensitive" => true})
    assert {:ok, "a.txt:2: hello["} = grep(root, "hello[")
    assert {:ok, "a.txt:2: hello["} = grep(root, "HELLO[", %{"case_sensitive" => false})
    assert {:ok, "a.txt:1: HéLLo"} = grep(root, "HéLLo")
    assert {:ok, no_match} = grep(root, "absent")
    assert no_match == "No matches found for 'absent'"
  end

  test "small invalid candidates do not consume a fictional scan budget", %{tmp_dir: root} do
    for n <- 1..10, do: File.write!(Path.join(root, "#{n}.txt"), <<255>>)
    File.write!(Path.join(root, "z.txt"), "needle")
    assert {:ok, "z.txt:1: needle"} = grep(root, "needle")
  end

  test "grep skips a read chunk containing invalid UTF-8 even after ten matches", %{tmp_dir: root} do
    File.write!(Path.join(root, "invalid"), String.duplicate("needle\n", 20) <> <<255>>)
    assert {:ok, "No matches found for 'needle'"} = grep(root, "needle")
  end

  test "grep preserves newline and Unicode across chunks", %{tmp_dir: root} do
    File.write!(Path.join(root, "split"), String.duplicate("a", 16_383) <> "界\r\nneedle")
    assert {:ok, "split:2: needle"} = grep(root, "^needle$")
    assert {:ok, output} = grep(root, "界")
    assert String.valid?(output)
    assert output =~ "界"
  end

  test "grep stops at its independent output and global scan byte limits", %{tmp_dir: root} do
    for n <- 1..6 do
      File.write!(
        Path.join(root, "#{n}.txt"),
        String.duplicate("needle" <> String.duplicate("x", 60_000) <> "\n", 5)
      )
    end

    assert {:ok, output} = grep(root, "needle")
    assert byte_size(output) < 257_000
    assert output =~ "output byte limit"
    assert output =~ "incomplete"

    for n <- 1..6 do
      File.write!(Path.join(root, "#{n}.txt"), String.duplicate("xxxxxxxxxxxxxxx\n", 150_000))
    end

    assert {:ok, output} = grep(root, "absent")
    assert output =~ "global scan byte limit"
    assert output =~ "incomplete"
    refute output =~ "No matches found"
  end

  test "scanner read-ahead stays fixed and halting stops before later chunks", %{tmp_dir: root} do
    alias IexCode.Tools.BoundedFile

    for size <- [8_000_000, 16_000_000] do
      File.write!(Path.join(root, "large"), String.duplicate("line\n", div(size, 5)))

      callback = fn _line, index, acc ->
        if index == 800, do: {:halt, :line_limit, acc + 1}, else: {:cont, acc + 1}
      end

      assert {:ok, result} = BoundedFile.scan(Path.join(root, "large"), 0, callback)
      assert result.acc == 800
      assert result.lines == 800
      assert result.bytes == 16_384
      assert result.reason == :line_limit
    end

    File.write!(Path.join(root, "giant"), String.duplicate("x", 16_000_000))

    assert {:ok, result} =
             BoundedFile.scan(Path.join(root, "giant"), nil, fn _, _, acc -> {:cont, acc} end)

    assert result.reason == :giant_line
    assert result.bytes == 81_920

    File.write!(Path.join(root, "scan"), String.duplicate("x\n", 2_000_000))

    assert {:ok, result} =
             BoundedFile.scan(Path.join(root, "scan"), nil, fn _, _, acc -> {:cont, acc} end)

    assert result.reason == :scan
    assert result.bytes == 2_097_152
  end

  test "native scan observations report aggregate bounds without content or paths", %{
    tmp_dir: root
  } do
    handler = {__MODULE__, make_ref()}
    owner = self()

    :telemetry.attach(
      handler,
      [:iex_code, :tools, :native_scan],
      fn _, measurements, metadata, _ ->
        send(owner, {:scan, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    File.write!(Path.join(root, "file"), String.duplicate("line\n", 20_000))
    assert {:ok, _} = read(root, "file")
    assert_receive {:scan, %{scanned_bytes: 16_384, output_lines: 800}, %{tool: :read_file}}
    assert {:ok, _} = grep(root, "line")

    assert_receive {:scan, %{scanned_bytes: 16_384, output_matches: 10, eligible_files: 1},
                    %{tool: :grep_search}}
  end

  test "grep is ordered and prunes excluded directories and extensions", %{tmp_dir: root} do
    for name <- ["z.txt", "a/b.txt", "a.txt", "a/c.txt"] do
      File.mkdir_p!(Path.dirname(Path.join(root, name)))
      File.write!(Path.join(root, name), "needle\n")
    end

    for directory <- ["_build", "deps", "node_modules", ".git"] do
      File.mkdir_p!(Path.join(root, "#{directory}/nested"))
      File.write!(Path.join(root, "#{directory}/nested/secret.txt"), "needle EXCLUDED")
    end

    File.write!(Path.join(root, "image.PNG"), "needle EXCLUDED")
    expected = "a.txt:1: needle\na/b.txt:1: needle\na/c.txt:1: needle\nz.txt:1: needle"
    assert {:ok, ^expected} = grep(root, "needle")
    assert {:ok, ^expected} = grep(root, "needle")
  end

  test "grep result and eligible file limits identify unfinished work", %{tmp_dir: root} do
    for n <- 1..510 do
      name = n |> Integer.to_string() |> String.pad_leading(4, "0")
      File.write!(Path.join(root, "#{name}.txt"), String.duplicate("needle\n", 20))
    end

    assert {:ok, output} = grep(root, "needle")
    assert length(Regex.scan(~r/^\d+\.txt:\d+:/m, output)) == 100
    assert output =~ "0010.txt:10:"
    refute output =~ "0011.txt:"
    assert output =~ "incomplete"
    assert output =~ "narrow"

    assert {:ok, output} = grep(root, "absent")
    assert output =~ "incomplete"
    assert output =~ "500"
    refute output =~ "No matches found"
  end

  test "grep giant lines and sparse traversal cannot falsely report no matches", %{tmp_dir: root} do
    File.write!(Path.join(root, "giant"), String.duplicate("x", 8_000_000) <> "needle")
    assert {:ok, output} = grep(root, "needle")
    assert output =~ "incomplete"
    refute output =~ "No matches found"
    File.rm!(Path.join(root, "giant"))

    for n <- 1..5_010 do
      File.mkdir_p!(Path.join(root, "d#{n}"))
    end

    assert {:ok, output} = grep(root, "needle")
    assert output =~ "incomplete"
    assert output =~ "traversal"
    refute output =~ "No matches found"
  end

  test "both tools reject escape requests and grep contains every candidate", %{tmp_dir: tmp} do
    root = Path.join(tmp, "workspace")
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.write!(Path.join(root, "inside"), "needle")
    File.write!(Path.join(outside, "sentinel"), "OUTSIDE_SENTINEL")
    File.ln_s!(outside, Path.join(root, "out_dir"))
    File.ln_s!(Path.join(outside, "sentinel"), Path.join(root, "out_file"))
    File.ln_s!("cycle_b", Path.join(root, "cycle_a"))
    File.ln_s!("cycle_a", Path.join(root, "cycle_b"))
    File.ln_s!("missing", Path.join(root, "broken"))
    File.ln_s!("inside", Path.join(root, "alias"))

    for path <- ["../outside/sentinel", Path.join(outside, "sentinel"), "out_file", "out_dir"] do
      assert {:error, message} = read(root, path)
      refute message =~ "OUTSIDE_SENTINEL"
      assert {:error, message} = grep(root, "OUTSIDE_SENTINEL", %{"path" => path})
      refute message =~ "OUTSIDE_SENTINEL"
    end

    assert {:ok, output} = grep(root, "OUTSIDE_SENTINEL|needle")
    assert output =~ "inside:1: needle"
    refute output =~ "OUTSIDE_SENTINEL"
    assert {:ok, output} = read(root, Path.join(root, "inside"))
    assert output == "1: needle"
    assert {:ok, output} = grep(root, "needle", %{"path" => root})
    assert output =~ "inside:1: needle"
    assert {:error, _} = read(root, "cycle_a")
    assert {:error, _} = read(root, "broken")
  end

  defp read(root, path, args \\ %{}) do
    Tools.execute("read_file", Map.put(args, "path", path), root)
  end

  defp grep(root, query, args \\ %{}) do
    Tools.execute("grep_search", Map.put(args, "query", query), root)
  end
end

defmodule IexCode.Tools.BoundedFileToolsTest do
  use ExUnit.Case, async: false

  alias IexCode.Tools

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "bounded-files-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{tmp_dir: root}
  end

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

  test "grep validates later chunks and incomplete UTF8 after collecting ten matches", %{
    tmp_dir: root
  } do
    prefix = String.duplicate("needle\n", 10) <> String.duplicate("padding\n", 5_000)

    for tail <- [<<255>>, <<226, 130>>] do
      File.write!(Path.join(root, "invalid"), prefix <> tail)
      assert {:ok, "No matches found for 'needle'"} = grep(root, "needle")
    end

    File.write!(Path.join(root, "invalid"), prefix <> "valid")
    assert {:ok, output} = grep(root, "needle")
    assert length(Regex.scan(~r/^invalid:\d+:/m, output)) == 10
    assert output =~ "incomplete"
    refute output =~ "unvalidated"
  end

  test "invalid provisional hundredth match does not stop the next valid candidate", %{
    tmp_dir: root
  } do
    for n <- 1..9 do
      File.write!(Path.join(root, "a#{n}"), String.duplicate("needle\n", 10))
    end

    File.write!(
      Path.join(root, "b"),
      String.duplicate("needle\n", 10) <> String.duplicate("padding\n", 5_000) <> <<255>>
    )

    File.write!(Path.join(root, "c"), "needle")
    assert {:ok, output} = grep(root, "needle")
    assert output =~ "c:1: needle"
    refute output =~ "b:1:"
  end

  test "oversized validation tails remain bounded and explicitly unvalidated", %{tmp_dir: root} do
    File.write!(
      Path.join(root, "large"),
      String.duplicate("needle\n", 10) <> String.duplicate("padding\n", 400_000) <> <<255>>
    )

    assert {:ok, output} = grep(root, "needle")
    assert output =~ "unvalidated"
    assert output =~ "scan byte limit"
    assert length(Regex.scan(~r/^large:\d+:/m, output)) == 10
  end

  test "excluded yielded names consume the shared traversal budget", %{tmp_dir: root} do
    observe_scans()

    for directory <- ["a", "b", "c"] do
      File.mkdir_p!(Path.join(root, directory))
      for n <- 1..2_001, do: File.write!(Path.join(root, "#{directory}/#{n}.png"), "")
    end

    assert {:ok, output} = grep(root, "needle")
    assert output =~ "traversal"
    assert output =~ "incomplete"
    refute output =~ "No matches found"
    assert_receive {:scan, %{traversal_entries: 5_000, eligible_files: 0}, _}
  end

  test "output ceiling commits after bounded validation and opens no next candidate", %{
    tmp_dir: root
  } do
    observe_scans()

    File.write!(
      Path.join(root, "a"),
      String.duplicate("needle" <> String.duplicate("x", 60_000) <> "\n", 5) <>
        String.duplicate("padding\n", 400_000)
    )

    File.write!(Path.join(root, "b"), "needle")
    assert {:ok, output} = grep(root, "needle")
    assert output =~ "output byte limit"
    assert output =~ "unvalidated"
    refute output =~ "b:1:"
    assert byte_size(output) <= 256_000
    assert_receive {:scan, %{eligible_files: 1, scanned_bytes: 2_097_152}, _}
  end

  test "exact retained output ceiling opens no next candidate", %{tmp_dir: root} do
    observe_scans()

    content =
      Enum.map_join([64_000, 64_000, 64_000, 63_464], fn size ->
        "needle" <> String.duplicate("x", size - 6) <> "\n"
      end)

    File.write!(Path.join(root, "a"), content)
    File.write!(Path.join(root, "b"), "not a match")
    assert {:ok, output} = grep(root, "needle")
    assert output =~ "output byte limit"
    assert_receive {:scan, %{eligible_files: 1, scanned_bytes: 255_468}, _}
  end

  test "oversized queries fail before progress and complete responses include notices within cap",
       %{
         tmp_dir: root
       } do
    owner = self()
    progress = fn _, text -> send(owner, {:progress, text}) end

    for size <- [4_097, 300_000] do
      assert {:error, error} =
               Tools.execute(
                 "grep_search",
                 %{"query" => String.duplicate("q", size)},
                 root,
                 progress
               )

      assert byte_size(error) <= 256_000
      refute_receive {:progress, _}
    end

    assert {:ok, accepted} = grep(root, String.duplicate("q", 4_096))
    assert byte_size(accepted) <= 256_000

    File.write!(
      Path.join(root, "wide"),
      String.duplicate(String.duplicate("界", 333) <> "\n", 500)
    )

    assert {:ok, output} = read(root, "wide", %{"start_line" => 1})
    assert byte_size(output) <= 256_000
    assert String.valid?(output)
    assert output =~ "incomplete"

    assert {:error, error} = read(root, "../" <> String.duplicate("界", 100_000))
    assert byte_size(error) <= 256_000
    assert String.valid?(error)
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

  test "validation-only scanning never calls the collector again and keeps line bounds", %{
    tmp_dir: root
  } do
    alias IexCode.Tools.BoundedFile
    owner = self()

    callback = fn _, _, acc ->
      send(owner, :collected)
      {:validate, :matches, acc + 1}
    end

    path = Path.join(root, "tail")
    File.write!(path, "needle\n" <> String.duplicate("padding\n", 5_000))

    assert {:ok, %{acc: 1, bytes: 40_007, reason: :matches}} =
             BoundedFile.scan(path, 0, callback, valid_utf8: true)

    assert_receive :collected
    refute_receive :collected

    File.write!(path, "needle\n" <> String.duplicate("x", 4_000_000))

    assert {:ok, %{acc: 1, bytes: 81_920, reason: :giant_line}} =
             BoundedFile.scan(path, 0, callback, valid_utf8: true)

    assert_receive :collected
    refute_receive :collected
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

    assert_receive {:scan, %{scanned_bytes: 100_000, output_matches: 10, eligible_files: 1},
                    %{tool: :grep_search}}
  end

  test "grep is ordered and prunes excluded directories and extensions", %{tmp_dir: root} do
    observe_scans()

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
    assert_receive {:scan, %{traversal_entries: 10, eligible_files: 4}, _}
    assert_receive {:scan, %{traversal_entries: 10, eligible_files: 4}, _}
  end

  test "file extension exclusions do not prune ordinary directories", %{tmp_dir: root} do
    observe_scans()
    File.mkdir!(Path.join(root, "archive.zip"))
    File.write!(Path.join(root, "archive.zip/notes.txt"), "needle nested\n")
    File.write!(Path.join(root, "control.txt"), "needle control\n")
    File.write!(Path.join(root, "actual.zip"), "needle excluded\n")

    assert {:ok, output} = grep(root, "needle")
    assert output =~ "control.txt:1: needle control"
    refute output =~ "actual.zip:"
    assert output == "archive.zip/notes.txt:1: needle nested\ncontrol.txt:1: needle control"
    assert {:ok, ^output} = grep(root, "needle")
    assert_receive {:scan, %{traversal_entries: 4, eligible_files: 2, output_matches: 2}, _}
    assert_receive {:scan, %{traversal_entries: 4, eligible_files: 2, output_matches: 2}, _}
  end

  test "unfinished root directories at two sizes discard arbitrary prefixes", %{tmp_dir: root} do
    observe_scans()

    for size <- [5_000, 6_000] do
      directory = Path.join(root, "wide#{size}")
      File.mkdir_p!(directory)
      for n <- 1..size, do: File.write!(Path.join(directory, "#{n}.png"), "")
      assert {:ok, output} = grep(root, "needle", %{"path" => directory})
      assert output =~ "incomplete"
      assert output =~ "traversal entry limit"
      assert_receive {:scan, %{traversal_entries: 5_000, eligible_files: 0}, _}
    end
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

  defp observe_scans do
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
  end
end

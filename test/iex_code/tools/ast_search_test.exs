defmodule IexCode.Tools.ASTSearchTest do
  use ExUnit.Case, async: false
  alias IexCode.Tools.ASTSearch

  @sample_code """
  defmodule Sample.Math do
    @moduledoc "Math utility module"
    @default_factor 10

    @doc "Multiplies two numbers"
    @spec multiply(number(), number()) :: number()
    def multiply(a, b) when is_number(a) and is_number(b) do
      a * b * @default_factor
    end

    defp secret_calc(x), do: x * 2

    defmacro custom_macro(expr) do
      quote do: unquote(expr) + 1
    end

    @type num_pair :: {number(), number()}
    @callback compute(number()) :: number()
  end
  """

  describe "extract_symbols/2" do
    test "extracts modules, functions, macros, specs, docs, attributes, types, and callbacks" do
      {:ok, symbols} = ASTSearch.extract_symbols(@sample_code, "lib/sample/math.ex")

      assert Enum.any?(symbols, &(&1.type in [:module, :defmodule] and &1.name == "Sample.Math"))
      assert Enum.any?(symbols, &(&1.type == :moduledoc and &1.name == "@moduledoc"))
      assert Enum.any?(symbols, &(&1.type == :attribute and &1.name == "@default_factor"))
      assert Enum.any?(symbols, &(&1.type == :doc and &1.name == "@doc"))
      assert Enum.any?(symbols, &(&1.type == :spec and &1.name == "multiply" and &1.arity == 2))

      assert Enum.any?(
               symbols,
               &(&1.type in [:function, :def] and &1.name == "multiply" and &1.arity == 2 and
                   &1.visibility == :public)
             )

      assert Enum.any?(
               symbols,
               &(&1.type in [:function, :defp] and &1.name == "secret_calc" and &1.arity == 1 and
                   &1.visibility == :private)
             )

      assert Enum.any?(
               symbols,
               &(&1.type in [:macro, :defmacro] and &1.name == "custom_macro" and &1.arity == 1 and
                   &1.visibility == :public)
             )

      assert Enum.any?(symbols, &(&1.type == :type and &1.name == "num_pair"))

      assert Enum.any?(
               symbols,
               &(&1.type == :callback and &1.name == "compute" and &1.arity == 1)
             )
    end
  end

  describe "Query filtering" do
    test "filters symbols by function name and arity" do
      {:ok, symbols} = ASTSearch.extract_symbols(@sample_code, "math.ex")
      filtered = ASTSearch.Query.filter(symbols, %{function: "multiply", arity: 2})

      assert length(filtered) == 2
      types = Enum.map(filtered, & &1.type)
      assert :spec in types
      assert :def in types
    end

    test "filters symbols by type" do
      {:ok, symbols} = ASTSearch.extract_symbols(@sample_code, "math.ex")
      filtered = ASTSearch.Query.filter(symbols, %{type: :function})

      assert length(filtered) == 2
      names = Enum.map(filtered, & &1.name)
      assert "multiply" in names
      assert "secret_calc" in names
    end

    test "filters symbols by string query" do
      {:ok, symbols} = ASTSearch.extract_symbols(@sample_code, "math.ex")
      filtered = ASTSearch.Query.filter(symbols, "Math utility")

      assert length(filtered) >= 1
      assert Enum.any?(filtered, &(&1.type == :moduledoc))
      assert Enum.any?(filtered, &(&1.type == :defmodule))
    end
  end

  describe "search/3 and search_file/3" do
    @tag :tmp_dir
    test "searches directory files and returns matching symbols", %{tmp_dir: tmp_dir} do
      math_file = Path.join(tmp_dir, "math.ex")
      File.write!(math_file, @sample_code)

      assert {:ok, results} = ASTSearch.search(tmp_dir, %{function: "secret_calc"})
      assert length(results) == 1
      assert hd(results).name == "secret_calc"
      assert hd(results).visibility == :private

      assert {:ok, file_results} = ASTSearch.search_file(math_file, "custom_macro")
      assert length(file_results) == 1
      assert hd(file_results).type in [:macro, :defmacro]
    end

    test "format_results/2 formats output string" do
      {:ok, symbols} = ASTSearch.extract_symbols(@sample_code, "math.ex")
      formatted = ASTSearch.format_results(symbols, include_code: false)
      assert formatted =~ "math.ex:1 [module] Sample.Math"
      assert formatted =~ "math.ex:7 [function] Sample.Math.multiply/2"
      assert formatted =~ "secret_calc/1 (private)"
    end
  end

  describe "search/4 hardening (contain_root, symlinks, max_file_bytes)" do
    @tag :tmp_dir
    test "preserves search/2, search/3 (opts or sub_path), and search/4 compatibility", %{
      tmp_dir: tmp_dir
    } do
      sub_dir = Path.join(tmp_dir, "lib/sub")
      File.mkdir_p!(sub_dir)

      File.write!(
        Path.join(tmp_dir, "root_mod.ex"),
        "defmodule RootMod do\n  def a, do: 1\nend\n"
      )

      File.write!(Path.join(sub_dir, "sub_mod.ex"), "defmodule SubMod do\n  def b, do: 2\nend\n")

      # search/2
      assert {:ok, all_defs} = ASTSearch.search(tmp_dir, %{type: :def})
      assert Enum.sort(Enum.map(all_defs, & &1.name)) == ["a", "b"]

      # search/3 with keyword opts
      assert {:ok, limited} = ASTSearch.search(tmp_dir, %{type: :def}, limit: 1)
      assert length(limited) == 1

      # search/3 with sub_path string
      assert {:ok, sub_defs} = ASTSearch.search(tmp_dir, %{type: :def}, "lib/sub")
      assert Enum.map(sub_defs, & &1.name) == ["b"]

      # search/4 with sub_path + opts
      assert {:ok, contained_defs} =
               ASTSearch.search(tmp_dir, %{type: :def}, "lib/sub", contain_root: true, limit: 5)

      assert Enum.map(contained_defs, & &1.name) == ["b"]
      assert hd(contained_defs).file == "lib/sub/sub_mod.ex"
    end

    @tag :tmp_dir
    test "contain_root: true rejects sub_path traversal and escaping symlinks", %{
      tmp_dir: tmp_dir
    } do
      workspace = Path.join(tmp_dir, "workspace")
      outside = Path.join(tmp_dir, "outside")
      File.mkdir_p!(Path.join(workspace, "lib"))
      File.mkdir_p!(outside)

      File.write!(
        Path.join(workspace, "lib/safe.ex"),
        "defmodule Safe.Mod do\n  def ok_fn, do: :ok\nend\n"
      )

      outside_file = Path.join(outside, "secret.ex")
      File.write!(outside_file, "defmodule Outside.Secret do\n  def leaked, do: :nope\nend\n")

      # Symlinks inside workspace escaping to outside file and outside directory
      File.ln_s!(outside_file, Path.join(workspace, "lib/escaped_file.ex"))
      File.ln_s!(outside, Path.join(workspace, "lib/escaped_dir"))

      # Internal symlink pointing into an excluded directory (`deps/`)
      deps_pkg = Path.join(workspace, "deps/secret_pkg")
      File.mkdir_p!(deps_pkg)

      File.write!(
        Path.join(deps_pkg, "dep_mod.ex"),
        "defmodule Dep.Mod do\n  def dep_fn, do: 1\nend\n"
      )

      File.ln_s!(deps_pkg, Path.join(workspace, "lib/deps_link"))

      # Symlink cycle inside workspace
      File.ln_s!("loop_b", Path.join(workspace, "lib/loop_a"))
      File.ln_s!("loop_a", Path.join(workspace, "lib/loop_b"))

      # 1. Positional sub_path escaping workspace
      assert {:error, :outside_workspace} =
               ASTSearch.search(workspace, %{}, "../outside", contain_root: true)

      # 2. Query map path escaping workspace
      assert {:error, :outside_workspace} =
               ASTSearch.search(workspace, %{path: "../outside"}, nil, contain_root: true)

      # 3. Keyword opts :path escaping workspace
      assert {:error, :outside_workspace} =
               ASTSearch.search(workspace, %{}, nil, path: outside, contain_root: true)

      # 4. Direct sub_path targeting an escaping symlink
      assert {:error, :outside_workspace} =
               ASTSearch.search(workspace, %{}, "lib/escaped_dir", contain_root: true)

      assert {:error, :outside_workspace} =
               ASTSearch.search(workspace, %{}, "lib/escaped_file.ex", contain_root: true)

      # 5. Directory scan with contain_root: true skips escaping symlinks & symlink loops
      assert {:ok, results} = ASTSearch.search(workspace, %{type: :def}, nil, contain_root: true)
      names = Enum.map(results, & &1.name)
      assert names == ["ok_fn"]
      refute "leaked" in names
    end

    @tag :tmp_dir
    test "skips oversized files above max_file_bytes (custom and default 1_048_576)", %{
      tmp_dir: tmp_dir
    } do
      small_file = Path.join(tmp_dir, "small.ex")
      large_file = Path.join(tmp_dir, "large.ex")
      over_1mb_file = Path.join(tmp_dir, "over_1mb.ex")

      File.write!(small_file, "defmodule Small do\n  def keep_me, do: :ok\nend\n")

      padding_2kb = String.duplicate("# padding line\n", 150)
      File.write!(large_file, "defmodule Large do\n#{padding_2kb}\ndef skip_2kb, do: :ok\nend\n")

      # Custom max_file_bytes
      assert {:ok, res_small} =
               ASTSearch.search(tmp_dir, %{type: :def}, nil,
                 contain_root: true,
                 max_file_bytes: 256
               )

      assert Enum.map(res_small, & &1.name) == ["keep_me"]

      assert {:error, :file_too_large} =
               ASTSearch.search_file(large_file, %{}, max_file_bytes: 256)

      # Default 1_048_576 (1 MiB) limit
      huge_comment = "#" <> String.duplicate("x", 1_050_000) <> "\n"

      File.write!(
        over_1mb_file,
        "defmodule Huge do\n#{huge_comment}def skip_huge, do: :ok\nend\n"
      )

      assert {:ok, res_default} =
               ASTSearch.search(tmp_dir, %{type: :def}, nil, contain_root: true)

      default_names = Enum.map(res_default, & &1.name)
      assert "keep_me" in default_names
      assert "skip_2kb" in default_names
      refute "skip_huge" in default_names
    end
  end
end

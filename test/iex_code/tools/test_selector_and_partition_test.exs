defmodule IexCode.Tools.TestSelectorAndPartitionTest do
  use ExUnit.Case, async: false

  alias IexCode.Tools.{TestRunner, TestSelector}
  alias IexCode.Tools.TestRunner.Result

  describe "TestSelector.select/2 ranked resolution" do
    @tag :tmp_dir
    test "ranks direct > convention mirrors > reverse module references deterministically", %{
      tmp_dir: tmp_dir
    } do
      setup_elixir_project(tmp_dir)

      assert {:ok, selection} =
               TestSelector.select(tmp_dir,
                 changed_files: [
                   "lib/my_app/billing.ex",
                   "test/my_app/direct_only_test.exs"
                 ]
               )

      assert selection.paths == [
               "test/my_app/direct_only_test.exs",
               "test/my_app/billing_test.exs",
               "test/my_app/billing_webhook_test.exs",
               "test/my_app/billing/refund_test.exs",
               "test/my_app/checkout_flow_test.exs",
               "test/my_app/short_alias_test.exs"
             ]

      assert selection.reasons["test/my_app/direct_only_test.exs"] == :direct
      assert selection.reasons["test/my_app/billing_test.exs"] == :mirror
      assert selection.reasons["test/my_app/billing_webhook_test.exs"] == :mirror
      assert selection.reasons["test/my_app/billing/refund_test.exs"] == :mirror
      assert selection.reasons["test/my_app/checkout_flow_test.exs"] == :reference
      assert selection.reasons["test/my_app/short_alias_test.exs"] == :reference
      assert selection.modules == ["MyApp.Billing"]
      refute selection.truncated?
    end

    @tag :tmp_dir
    test "deduplicates across tiers preserving highest-priority tier", %{tmp_dir: tmp_dir} do
      setup_elixir_project(tmp_dir)

      # billing_test.exs is both directly modified AND a mirror for billing.ex
      assert {:ok, selection} =
               TestSelector.select(tmp_dir,
                 changed_files: [
                   "lib/my_app/billing.ex",
                   "test/my_app/billing_test.exs"
                 ]
               )

      assert hd(selection.paths) == "test/my_app/billing_test.exs"
      assert selection.reasons["test/my_app/billing_test.exs"] == :direct
      assert Enum.count(selection.paths, &(&1 == "test/my_app/billing_test.exs")) == 1
    end

    @tag :tmp_dir
    test "respects max_targets bound and sets truncated?: true", %{tmp_dir: tmp_dir} do
      setup_elixir_project(tmp_dir)

      assert {:ok, bounded} =
               TestSelector.select(tmp_dir,
                 changed_files: ["lib/my_app/billing.ex", "test/my_app/direct_only_test.exs"],
                 max_targets: 3
               )

      assert length(bounded.paths) == 3

      assert bounded.paths == [
               "test/my_app/direct_only_test.exs",
               "test/my_app/billing_test.exs",
               "test/my_app/billing_webhook_test.exs"
             ]

      assert bounded.truncated? == true
    end

    @tag :tmp_dir
    test "handles nested defmodule and syntax-error fallback regex extraction", %{
      tmp_dir: tmp_dir
    } do
      setup_elixir_project(tmp_dir)

      File.write!(Path.join(tmp_dir, "lib/my_app/nested_broken.ex"), """
      defmodule MyApp.Outer do
        defmodule Billing do
          def broken(
        end
      end
      """)

      assert {:ok, selection} =
               TestSelector.select(tmp_dir,
                 changed_files: ["lib/my_app/nested_broken.ex"]
               )

      assert "test/my_app/checkout_flow_test.exs" in selection.paths
      assert "test/my_app/short_alias_test.exs" in selection.paths
    end

    @tag :tmp_dir
    test "rejects paths outside workspace, symlinks escaping workspace, and deps/_build", %{
      tmp_dir: tmp_dir
    } do
      setup_elixir_project(tmp_dir)

      outside_dir =
        Path.join(System.tmp_dir!(), "sel-outside-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside_dir)
      on_exit(fn -> File.rm_rf(outside_dir) end)

      outside_test = Path.join(outside_dir, "evil_test.exs")
      File.write!(outside_test, "defmodule EvilTest, do: use ExUnit.Case")
      File.ln_s!(outside_test, Path.join(tmp_dir, "test/symlink_escape_test.exs"))

      File.mkdir_p!(Path.join(tmp_dir, "deps/foo/test"))
      File.write!(Path.join(tmp_dir, "deps/foo/test/dep_test.exs"), "defmodule DepTest, do: nil")

      assert {:ok, selection} =
               TestSelector.select(tmp_dir,
                 changed_files: [
                   "../escape_test.exs",
                   outside_test,
                   "test/symlink_escape_test.exs",
                   "deps/foo/test/dep_test.exs",
                   "_build/test/lib/my_app/billing.ex"
                 ]
               )

      assert selection.paths == []
      assert selection.changed_files == []
    end

    @tag :tmp_dir
    test "discovers modified, staged, and untracked files from git workspace", %{tmp_dir: tmp_dir} do
      setup_elixir_project(tmp_dir)

      {_, 0} = System.cmd("git", ["init"], cd: tmp_dir)
      {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_dir)
      {_, 0} = System.cmd("git", ["config", "user.name", "Tester"], cd: tmp_dir)
      {_, 0} = System.cmd("git", ["add", "."], cd: tmp_dir)
      {_, 0} = System.cmd("git", ["commit", "-m", "initial"], cd: tmp_dir)

      # Clean repo -> empty selection
      assert {:ok, clean_sel} = TestSelector.select(tmp_dir)
      assert clean_sel.paths == []

      # Modify tracked lib file + create untracked direct test
      File.write!(
        Path.join(tmp_dir, "lib/my_app/billing.ex"),
        File.read!(Path.join(tmp_dir, "lib/my_app/billing.ex")) <> "\n# changed\n"
      )

      File.write!(
        Path.join(tmp_dir, "test/my_app/new_untracked_test.exs"),
        "defmodule NewUntrackedTest do\n  use ExUnit.Case\nend\n"
      )

      assert {:ok, dirty_sel} = TestSelector.select(tmp_dir)
      assert hd(dirty_sel.paths) == "test/my_app/new_untracked_test.exs"
      assert dirty_sel.reasons["test/my_app/new_untracked_test.exs"] == :direct
      assert "test/my_app/billing_test.exs" in dirty_sel.paths
      assert "test/my_app/checkout_flow_test.exs" in dirty_sel.paths
    end
  end

  describe "TestRunner partition validation and cleanup on failure" do
    @tag :tmp_dir
    test "rejects unsafe partition names containing path separators or globs", %{tmp_dir: tmp_dir} do
      assert {:error, {:invalid_partition, "../evil"}} =
               TestRunner.run(project_root: tmp_dir, partition: "../evil")

      assert {:error, {:invalid_partition, "p*"}} =
               TestRunner.run(project_root: tmp_dir, partition: "p*")
    end

    @tag :tmp_dir
    test "cleans up partition sqlite files even when tests fail", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "mix.exs"), """
      defmodule FailPartApp.MixProject do
        use Mix.Project
        def project, do: [app: :fail_part_app, version: "0.1.0"]
      end
      """)

      File.mkdir_p!(Path.join(tmp_dir, "test"))
      File.write!(Path.join(tmp_dir, "test/test_helper.exs"), "ExUnit.start()")

      File.write!(Path.join(tmp_dir, "test/fail_part_test.exs"), """
      defmodule FailPartTest do
        use ExUnit.Case
        test "creates db then fails" do
          part = System.get_env("MIX_TEST_PARTITION")
          File.write!("fail_part_app_test\#{part}.db", "db")
          File.write!("fail_part_app_test\#{part}.db-wal", "wal")
          assert false
        end
      end
      """)

      assert {:ok, %Result{status: :failed, failures_count: 1}} =
               TestRunner.run(
                 project_root: tmp_dir,
                 paths: ["test/fail_part_test.exs"],
                 partition: "_failp"
               )

      refute File.exists?(Path.join(tmp_dir, "fail_part_app_test_failp.db"))
      refute File.exists?(Path.join(tmp_dir, "fail_part_app_test_failp.db-wal"))
    end
  end

  defp setup_elixir_project(tmp_dir) do
    File.mkdir_p!(Path.join(tmp_dir, "lib/my_app"))
    File.mkdir_p!(Path.join(tmp_dir, "test/my_app/billing"))

    File.write!(Path.join(tmp_dir, "lib/my_app/billing.ex"), """
    defmodule MyApp.Billing do
      def charge(cents), do: {:ok, cents}
    end
    """)

    File.write!(Path.join(tmp_dir, "test/my_app/direct_only_test.exs"), """
    defmodule MyApp.DirectOnlyTest do
      use ExUnit.Case
      test "ok", do: assert true
    end
    """)

    File.write!(Path.join(tmp_dir, "test/my_app/billing_test.exs"), """
    defmodule MyApp.BillingTest do
      use ExUnit.Case
      test "charge", do: assert {:ok, 10} == MyApp.Billing.charge(10)
    end
    """)

    File.write!(Path.join(tmp_dir, "test/my_app/billing_webhook_test.exs"), """
    defmodule MyApp.BillingWebhookTest do
      use ExUnit.Case
      test "webhook", do: assert true
    end
    """)

    File.write!(Path.join(tmp_dir, "test/my_app/billing/refund_test.exs"), """
    defmodule MyApp.Billing.RefundTest do
      use ExUnit.Case
      test "refund", do: assert true
    end
    """)

    File.write!(Path.join(tmp_dir, "test/my_app/checkout_flow_test.exs"), """
    defmodule MyApp.CheckoutFlowTest do
      use ExUnit.Case
      alias MyApp.Billing

      test "checkout" do
        assert {:ok, 50} == Billing.charge(50)
      end
    end
    """)

    File.write!(Path.join(tmp_dir, "test/my_app/short_alias_test.exs"), """
    defmodule MyApp.ShortAliasTest do
      use ExUnit.Case
      alias MyApp.{Account, Billing}

      test "short alias" do
        assert {:ok, 25} == Billing.charge(25)
      end
    end
    """)

    File.write!(Path.join(tmp_dir, "test/my_app/unrelated_test.exs"), """
    defmodule MyApp.UnrelatedTest do
      use ExUnit.Case
      # Billing is only mentioned in a comment here
      test "unrelated" do
        assert "Billing" == "Billing"
      end
    end
    """)
  end
end

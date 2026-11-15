Code.require_file("lib/ast_renamer.ex", __DIR__)

ExUnit.start(autorun: false)

defmodule AstRenamerGradeTest do
  use ExUnit.Case

  test "renames def, defp, local calls, remote calls, and captures of matching arity only" do
    source = """
    defmodule Billing do
      @label "compute_tax should stay untouched in strings"

      def compute_tax(amount, rate) when amount > 0 do
        base = compute_tax(amount)
        compute_tax = %{compute_tax: :compute_tax}
        {base, helper(amount, rate), Billing.compute_tax(amount, rate), compute_tax, @label}
      end

      def compute_tax(amount), do: amount * 0.1

      defp helper(amount, rate) do
        f1 = &compute_tax/2
        f2 = &Billing.compute_tax/2
        f3 = &compute_tax/1
        {f1.(amount, rate), f2.(amount, rate), f3.(amount)}
      end
    end
    """

    assert {:ok, updated} = AstRenamer.rename_function(source, :compute_tax, :calculate_tax, 2)

    # Matching arity definitions, remote calls, and captures were renamed
    assert updated =~ "calculate_tax(amount, rate)"
    assert updated =~ "Billing.calculate_tax(amount, rate)"
    assert updated =~ "&calculate_tax/2"
    assert updated =~ "&Billing.calculate_tax/2"

    # Strings, atoms, map keys, variables, and arity-1 overload/calls/captures were preserved
    assert updated =~ ~s("compute_tax should stay untouched in strings")
    assert updated =~ "def compute_tax(amount)"
    assert updated =~ "base = compute_tax(amount)"
    assert updated =~ "&compute_tax/1"
    assert updated =~ ":compute_tax"
    assert updated =~ "compute_tax: :compute_tax"

    # Updated source must remain valid Elixir and evaluate identically
    assert {:ok, _ast} = Code.string_to_quoted(updated)
  end

  test "handles 0-arity def without parens and remote 0-arity calls without touching variables" do
    source = """
    defmodule Ping do
      def ping do
        ping = :ok
        {ping, Ping.ping()}
      end
    end
    """

    assert {:ok, updated} = AstRenamer.rename_function(source, :ping, :pong, 0)
    assert updated =~ "def pong"
    assert updated =~ "Ping.pong()"
    assert updated =~ "ping = :ok"
    assert updated =~ "{ping, Ping.pong()}"
  end

  test "returns {:error, reason} on invalid Elixir syntax" do
    assert {:error, _reason} = AstRenamer.rename_function("def broken(", :foo, :bar, 0)
  end
end

case ExUnit.run() do
  %{failures: 0} -> System.halt(0)
  _ -> System.halt(1)
end

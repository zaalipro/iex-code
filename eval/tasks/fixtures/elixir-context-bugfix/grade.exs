Code.require_file("lib/ledger.ex", __DIR__)
Code.require_file("lib/orders.ex", __DIR__)

ExUnit.start(autorun: false)

defmodule ContextBugfixGradeTest do
  use ExUnit.Case

  defp base_state do
    %{
      accounts: %{
        "acct-1" => %{id: "acct-1", balance_cents: 1_000, reserved_cents: 0},
        "acct-2" => %{id: "acct-2", balance_cents: 500, reserved_cents: 0}
      },
      orders: %{}
    }
  end

  test "accumulates reservations across multiple orders and checks available balance" do
    state = base_state()

    assert {:ok, o1, state} =
             Orders.place_order(state, "acct-1", %{id: "ord-1", unit_price_cents: 300, qty: 2})

    assert o1.amount_cents == 600
    assert state.accounts["acct-1"].reserved_cents == 600

    assert {:ok, o2, state} =
             Orders.place_order(state, "acct-1", %{id: "ord-2", unit_price_cents: 200, qty: 1})

    assert o2.amount_cents == 200
    assert state.accounts["acct-1"].reserved_cents == 800

    # Available is 200, so 300 must fail without mutating reserved_cents
    assert {:error, :insufficient_funds} =
             Orders.place_order(state, "acct-1", %{id: "ord-3", unit_price_cents: 300, qty: 1})

    assert state.accounts["acct-1"].reserved_cents == 800
    refute Map.has_key?(state.orders, "ord-3")
  end

  test "rejects duplicate order ids and invalid inputs without mutating state" do
    state = base_state()

    assert {:ok, _o1, state} =
             Orders.place_order(state, "acct-1", %{id: "ord-1", unit_price_cents: 200, qty: 1})

    assert {:error, :duplicate_order} =
             Orders.place_order(state, "acct-1", %{id: "ord-1", unit_price_cents: 100, qty: 1})

    assert state.accounts["acct-1"].reserved_cents == 200

    assert {:error, :invalid_order} =
             Orders.place_order(state, "acct-1", %{id: "bad", unit_price_cents: 100, qty: 0})

    assert {:error, :account_not_found} =
             Orders.place_order(state, "missing", %{id: "ord-9", unit_price_cents: 100, qty: 1})
  end

  test "cancel_order releases reservation once and rejects double cancellation" do
    state = base_state()

    {:ok, _o1, state} =
      Orders.place_order(state, "acct-1", %{id: "ord-1", unit_price_cents: 400, qty: 1})

    {:ok, _o2, state} =
      Orders.place_order(state, "acct-1", %{id: "ord-2", unit_price_cents: 300, qty: 1})

    assert {:ok, cancelled, state} = Orders.cancel_order(state, "ord-1")
    assert cancelled.status == :cancelled
    assert state.accounts["acct-1"].reserved_cents == 300

    assert {:error, :already_cancelled} = Orders.cancel_order(state, "ord-1")
    assert state.accounts["acct-1"].reserved_cents == 300
    assert {:error, :order_not_found} = Orders.cancel_order(state, "ord-missing")
  end

  test "list_orders filters by account and status and sorts ascending by id" do
    state = base_state()

    {:ok, _, state} =
      Orders.place_order(state, "acct-1", %{id: "ord-2", unit_price_cents: 100, qty: 1})

    {:ok, _, state} =
      Orders.place_order(state, "acct-1", %{id: "ord-1", unit_price_cents: 100, qty: 1})

    {:ok, _, state} =
      Orders.place_order(state, "acct-2", %{id: "ord-3", unit_price_cents: 100, qty: 1})

    {:ok, _, state} = Orders.cancel_order(state, "ord-1")

    assert Enum.map(Orders.list_orders(state, "acct-1"), & &1.id) == ["ord-1", "ord-2"]

    assert Enum.map(Orders.list_orders(state, "acct-1", status: :pending), & &1.id) == ["ord-2"]

    assert Enum.map(Orders.list_orders(state, "acct-1", status: :cancelled), & &1.id) == [
             "ord-1"
           ]
  end
end

case ExUnit.run() do
  %{failures: 0} -> System.halt(0)
  _ -> System.halt(1)
end

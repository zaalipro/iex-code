Code.require_file("lib/pricing.ex", __DIR__)
Code.require_file("lib/checkout.ex", __DIR__)
Code.require_file("lib/invoice.ex", __DIR__)

ExUnit.start(autorun: false)

defmodule MultiFileContractGradeTest do
  use ExUnit.Case

  @items [
    %{price_cents: 1_000, qty: 2},
    %{price_cents: 500, qty: 1}
  ]

  test "Pricing.calculate_total/2 preserves default and applies discount then tax" do
    assert Pricing.calculate_total(@items) == 2_500
    assert Pricing.calculate_total(@items, discount_cents: 500, tax_rate: 0.1) == 2_200
    assert Pricing.calculate_total(@items, discount_cents: 10_000, tax_rate: 0.2) == 0
  end

  test "Checkout.summarize/1 passes discount_cents and tax_rate" do
    cart = %{items: @items, discount_cents: 500, tax_rate: 0.1}
    assert Checkout.summarize(cart) == %{total_cents: 2_200, item_count: 3}
  end

  test "Invoice.render/1 passes discount_cents and tax_rate" do
    order = %{id: "inv-42", items: @items, discount_cents: 300, tax_rate: 0.05}
    assert Invoice.render(order) == %{id: "inv-42", total_cents: 2_310}
  end
end

case ExUnit.run() do
  %{failures: 0} -> System.halt(0)
  _ -> System.halt(1)
end

defmodule Checkout do
  @moduledoc """
  Computes a checkout summary from a cart map.
  """

  @spec summarize(map()) :: %{total_cents: integer(), item_count: non_neg_integer()}
  def summarize(%{items: items} = cart) do
    _discount = Map.get(cart, :discount_cents, 0)
    _tax_rate = Map.get(cart, :tax_rate, 0.0)
    total = Pricing.calculate_total(items)
    count = Enum.reduce(items, 0, fn item, acc -> acc + item.qty end)

    %{total_cents: total, item_count: count}
  end
end

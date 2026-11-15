defmodule Invoice do
  @moduledoc """
  Renders an order invoice summary.
  """

  @spec render(map()) :: %{id: String.t(), total_cents: integer()}
  def render(%{id: id, items: items} = order) do
    _discount = Map.get(order, :discount_cents, 0)
    _tax_rate = Map.get(order, :tax_rate, 0.0)
    total = Pricing.calculate_total(items)

    %{id: id, total_cents: total}
  end
end

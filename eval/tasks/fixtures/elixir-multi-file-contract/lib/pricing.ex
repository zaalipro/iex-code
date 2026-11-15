defmodule Pricing do
  @moduledoc """
  Line-item pricing calculation.
  """

  @spec calculate_total([%{price_cents: integer(), qty: pos_integer()}]) :: integer()
  def calculate_total(items) when is_list(items) do
    Enum.reduce(items, 0, fn item, acc ->
      acc + item.price_cents * item.qty
    end)
  end
end

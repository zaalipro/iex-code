defmodule Ledger do
  @moduledoc """
  Account balance and reservation helper.
  """

  @type account :: %{
          required(:id) => String.t(),
          required(:balance_cents) => non_neg_integer(),
          required(:reserved_cents) => non_neg_integer()
        }

  @spec available_cents(account()) :: integer()
  def available_cents(%{balance_cents: balance, reserved_cents: reserved}) do
    balance - reserved
  end

  @spec reserve(account(), pos_integer()) ::
          {:ok, account()} | {:error, :insufficient_funds | :invalid_amount}
  def reserve(account, amount) when is_integer(amount) and amount > 0 do
    if available_cents(account) >= amount do
      {:ok, %{account | reserved_cents: account.reserved_cents + amount}}
    else
      {:error, :insufficient_funds}
    end
  end

  def reserve(_account, _amount), do: {:error, :invalid_amount}

  @spec release(account(), pos_integer()) :: account()
  def release(account, amount) when is_integer(amount) and amount > 0 do
    %{account | reserved_cents: max(0, account.reserved_cents - amount)}
  end
end

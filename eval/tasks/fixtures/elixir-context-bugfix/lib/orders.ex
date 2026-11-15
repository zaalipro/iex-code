defmodule Orders do
  @moduledoc """
  Context for placing, cancelling, and querying customer orders backed by `Ledger`.
  """

  @type order :: %{
          required(:id) => String.t(),
          required(:account_id) => String.t(),
          required(:amount_cents) => pos_integer(),
          required(:status) => :pending | :cancelled
        }

  @type state :: %{
          required(:accounts) => %{String.t() => Ledger.account()},
          required(:orders) => %{String.t() => order()}
        }

  @spec place_order(state(), String.t(), map()) ::
          {:ok, order(), state()}
          | {:error, :account_not_found | :invalid_order | :insufficient_funds | :duplicate_order}
  def place_order(state, account_id, %{id: order_id, unit_price_cents: price, qty: qty})
      when is_binary(order_id) and order_id != "" and is_integer(price) and price > 0 and
             is_integer(qty) and qty > 0 do
    with {:ok, account} <- fetch_account(state, account_id) do
      total_cents = price * qty

      if account.balance_cents >= total_cents do
        updated_account = %{account | reserved_cents: total_cents}

        order = %{
          id: order_id,
          account_id: account_id,
          amount_cents: total_cents,
          status: :pending
        }

        new_state = %{
          state
          | accounts: Map.put(state.accounts, account_id, updated_account),
            orders: Map.put(state.orders, order_id, order)
        }

        {:ok, order, new_state}
      else
        {:error, :insufficient_funds}
      end
    end
  end

  def place_order(_state, _account_id, _attrs), do: {:error, :invalid_order}

  @spec cancel_order(state(), String.t()) ::
          {:ok, order(), state()}
          | {:error, :order_not_found | :already_cancelled | :account_not_found}
  def cancel_order(state, order_id) do
    case Map.fetch(state.orders, order_id) do
      {:ok, order} ->
        with {:ok, account} <- fetch_account(state, order.account_id) do
          updated_account = %{
            account
            | reserved_cents: account.reserved_cents - order.amount_cents
          }

          cancelled = %{order | status: :cancelled}

          new_state = %{
            state
            | accounts: Map.put(state.accounts, order.account_id, updated_account),
              orders: Map.put(state.orders, order_id, cancelled)
          }

          {:ok, cancelled, new_state}
        end

      :error ->
        {:error, :order_not_found}
    end
  end

  @spec list_orders(state(), String.t(), keyword()) :: [order()]
  def list_orders(state, account_id, opts \\ []) do
    status = Keyword.get(opts, :status)

    state.orders
    |> Map.values()
    |> Enum.filter(fn order ->
      order.account_id == account_id and (is_nil(status) or order.status == status)
    end)
    |> Enum.sort_by(& &1.id, :desc)
  end

  defp fetch_account(state, account_id) do
    case Map.fetch(state.accounts, account_id) do
      {:ok, account} -> {:ok, account}
      :error -> {:error, :account_not_found}
    end
  end
end

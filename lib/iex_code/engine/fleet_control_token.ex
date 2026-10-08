defmodule IexCode.Engine.FleetControlToken do
  @moduledoc false

  @paused 1
  @cancelled 2

  def new do
    ref = :atomics.new(2, signed: false)
    %{ref: ref}
  end

  # Durable attempts add a monotonic deadline. Ordinary fleet tokens retain
  # their existing pause/cancel behavior.
  def new_authority do
    %{
      ref: :atomics.new(2, signed: false),
      expiry: :atomics.new(1, signed: true),
      identity: make_ref()
    }
    |> then(fn token ->
      :atomics.put(token.expiry, 1, System.monotonic_time(:millisecond))
      token
    end)
  end

  def pause(%{ref: ref}), do: :atomics.put(ref, @paused, 1)
  def resume(%{ref: ref}), do: :atomics.put(ref, @paused, 0)
  def cancel(%{ref: ref}), do: :atomics.put(ref, @cancelled, 1)

  def cancelled?(%{ref: ref} = token),
    do: :atomics.get(ref, @cancelled) == 1 or expired?(token)

  def paused?(%{ref: ref}), do: :atomics.get(ref, @paused) == 1

  defp expired?(%{expiry: expiry}),
    do: System.monotonic_time(:millisecond) >= :atomics.get(expiry, 1)

  defp expired?(_token), do: false

  def checkpoint(token) do
    cond do
      cancelled?(token) ->
        :cancelled

      paused?(token) ->
        receive do
        after
          25 -> checkpoint(token)
        end

      true ->
        :ok
    end
  end
end

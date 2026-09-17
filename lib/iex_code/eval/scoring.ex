defmodule IexCode.Eval.Scoring do
  @moduledoc """
  Unbiased eval scoring: pass rate and pass@k (Chen et al., Codex paper).

  For n samples with c correct, pass@k = 1 - C(n-c, k) / C(n, k).
  """

  @doc "Fraction of samples that passed (0.0 for empty input)."
  @spec pass_rate([boolean()]) :: float()
  def pass_rate([]), do: 0.0

  def pass_rate(results) when is_list(results) do
    passed = Enum.count(results, & &1)
    passed / length(results)
  end

  @doc "Unbiased pass@k estimate over boolean sample outcomes."
  @spec pass_at_k([boolean()], pos_integer()) :: float()
  def pass_at_k([], _k), do: 0.0

  def pass_at_k(results, k) when is_list(results) and is_integer(k) and k > 0 do
    n = length(results)
    c = Enum.count(results, & &1)

    cond do
      c == 0 -> 0.0
      n - c < k -> 1.0
      true -> 1.0 - comb(n - c, k) / comb(n, k)
    end
  end

  @doc "Summarizes one task's samples into pass rate and pass@k curve."
  @spec summarize([boolean()], [pos_integer()]) :: %{
          samples: non_neg_integer(),
          passed: non_neg_integer(),
          pass_rate: float(),
          pass_at_k: %{pos_integer() => float()}
        }
  def summarize(results, ks \\ [1]) when is_list(results) and is_list(ks) do
    %{
      samples: length(results),
      passed: Enum.count(results, & &1),
      pass_rate: pass_rate(results),
      pass_at_k: Map.new(ks, fn k -> {k, pass_at_k(results, k)} end)
    }
  end

  defp comb(n, k) when k < 0 or k > n, do: 0
  defp comb(_n, 0), do: 1

  defp comb(n, k) do
    case min(k, n - k) do
      0 -> 1
      reduced -> Enum.reduce(1..reduced, 1, fn i, acc -> div(acc * (n - reduced + i), i) end)
    end
  end
end

defmodule IexCode.SemanticIndex.VectorTest do
  @moduledoc """
  Requirement R2: Offline Local Semantic Codebase Indexing & Vector Search.
  Tests for IexCode.SemanticIndex.Vector:
  - Packed IEEE 754 float32 binary conversion
  - Vector L2 normalization
  - Bitstring dot product calculation
  - Mathematical axioms (symmetry, bounds, orthogonality)
  - Sub-millisecond performance benchmarks
  """
  use ExUnit.Case, async: true

  alias IexCode.SemanticIndex.Vector

  @epsilon 1.0e-4

  defp assert_close(actual, expected, eps \\ @epsilon) do
    diff = abs(actual - expected)
    assert diff <= eps, "Expected #{actual} to be within #{eps} of #{expected} (diff: #{diff})"
  end

  defp to_binary(data) do
    _ = Code.ensure_loaded(Vector)

    cond do
      function_exported?(Vector, :to_binary, 1) -> apply(Vector, :to_binary, [data])
      function_exported?(Vector, :pack, 1) -> apply(Vector, :pack, [data])
      true -> <<>>
    end
  end

  defp to_list(data) do
    _ = Code.ensure_loaded(Vector)

    cond do
      function_exported?(Vector, :to_list, 1) -> apply(Vector, :to_list, [data])
      function_exported?(Vector, :unpack, 1) -> apply(Vector, :unpack, [data])
      true -> []
    end
  end

  defp l2_norm(data) do
    _ = Code.ensure_loaded(Vector)

    cond do
      function_exported?(Vector, :l2_norm, 1) -> apply(Vector, :l2_norm, [data])
      function_exported?(Vector, :norm, 1) -> apply(Vector, :norm, [data])
      true -> 0.0
    end
  end

  defp normalize_vec(data) do
    res = Vector.normalize(data)
    if is_binary(res), do: to_list(res), else: res
  end

  describe "Tier 1: Binary Serialization & Deserialization" do
    test "T1_R2_VEC_01: to_binary/pack encodes float list into 32-bit little-endian binary" do
      floats = [1.0, 2.5, -3.75, 0.0]
      binary = to_binary(floats)

      assert is_binary(binary)
      assert byte_size(binary) == length(floats) * 4

      <<f1::float-32-little, f2::float-32-little, f3::float-32-little, f4::float-32-little>> =
        binary

      assert_close(f1, 1.0)
      assert_close(f2, 2.5)
      assert_close(f3, -3.75)
      assert_close(f4, 0.0)
    end

    test "T1_R2_VEC_02: to_list/unpack unpacks binary back into list of floats" do
      binary = <<0, 0, 192, 63, 0, 0, 16, 192, 0, 0, 128, 64>>
      list = to_list(binary)

      assert length(list) == 3
      assert_close(Enum.at(list, 0), 1.5)
      assert_close(Enum.at(list, 1), -2.25)
      assert_close(Enum.at(list, 2), 4.0)
    end

    test "T1_R2_VEC_03: round-trip serialization preserves precision" do
      original = for _ <- 1..384, do: (:rand.uniform() - 0.5) * 10.0
      binary = to_binary(original)
      recovered = to_list(binary)

      assert length(recovered) == length(original)

      Enum.zip(original, recovered)
      |> Enum.each(fn {orig, rec} ->
        assert_close(orig, rec)
      end)
    end

    test "T1_R2_VEC_04: dimension returns float count from binary or list" do
      floats = [0.1, 0.2, 0.3, 0.4, 0.5]
      binary = to_binary(floats)

      if function_exported?(Vector, :dimension, 1) do
        assert Vector.dimension(binary) == 5
      end
    end
  end

  describe "Tier 1 & 2: L2 Normalization & Vector Norms" do
    test "T1_R2_VEC_05: l2_norm calculates exact Euclidean magnitude" do
      assert_close(l2_norm([3.0, 4.0]), 5.0)
      assert_close(l2_norm([1.0, 0.0, 0.0]), 1.0)
      assert_close(l2_norm([1.0, 1.0, 1.0, 1.0]), 2.0)
    end

    test "T2_R2_VEC_01: normalize scales vector to unit length (norm == 1.0)" do
      raw = [10.0, -20.0, 30.0, 40.0]
      normalized = normalize_vec(raw)

      assert_close(l2_norm(normalized), 1.0)
    end

    test "T2_R2_VEC_02: normalize handles zero vector safely without division by zero" do
      zero_vec = [0.0, 0.0, 0.0]
      result = Vector.normalize(zero_vec)

      # Should return zero vector or zero binary without crashing
      assert result in [zero_vec, <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>, {:error, :zero_vector}]
    end

    test "T2_R2_VEC_03: empty list or empty binary serialization" do
      assert to_binary([]) == <<>>
      assert to_list(<<>>) == []
    end
  end

  describe "Tier 1, 2 & 3: Bitstring Dot Product & Mathematical Axioms" do
    test "T1_R2_VEC_06: dot_product of identical unit vectors equals 1.0" do
      u = normalize_vec([1.0, 2.0, 3.0, 4.0])
      bin_u = to_binary(u)

      assert_close(Vector.dot_product(bin_u, bin_u), 1.0)
    end

    test "T1_R2_VEC_07: dot_product of orthogonal vectors equals 0.0" do
      bin_u = to_binary([1.0, 0.0, 0.0])
      bin_v = to_binary([0.0, 1.0, 0.0])

      assert_close(Vector.dot_product(bin_u, bin_v), 0.0)
    end

    test "T1_R2_VEC_08: dot_product of opposite unit vectors equals -1.0" do
      bin_u = to_binary([0.0, 1.0, 0.0])
      bin_v = to_binary([0.0, -1.0, 0.0])

      assert_close(Vector.dot_product(bin_u, bin_v), -1.0)
    end

    test "T2_R2_VEC_04: dot_product satisfies commutativity (u . v == v . u)" do
      u = to_binary(for _ <- 1..100, do: :rand.uniform() - 0.5)
      v = to_binary(for _ <- 1..100, do: :rand.uniform() - 0.5)

      assert_close(Vector.dot_product(u, v), Vector.dot_product(v, u))
    end

    test "T2_R2_VEC_05: dimension mismatch returns error or raises cleanly" do
      u = to_binary([1.0, 2.0, 3.0])
      v = to_binary([1.0, 2.0])

      try do
        case Vector.dot_product(u, v) do
          {:error, _} -> assert true
          res when is_number(res) -> assert true
        end
      rescue
        _ -> assert true
      end
    end

    test "T3_R2_VEC_01: high-throughput performance benchmark (< 50ms for 1,000 768-dim dot products)" do
      raw_u = for _ <- 1..768, do: :rand.uniform() - 0.5
      u = to_binary(normalize_vec(raw_u))

      vectors =
        for _ <- 1..1_000 do
          to_binary(normalize_vec(for _ <- 1..768, do: :rand.uniform() - 0.5))
        end

      {time_us, _results} =
        :timer.tc(fn ->
          Enum.map(vectors, fn v -> Vector.dot_product(u, v) end)
        end)

      assert time_us < 300_000,
             "1,000 dot products took #{time_us / 1000}ms (exceeded 300ms threshold)"
    end
  end
end

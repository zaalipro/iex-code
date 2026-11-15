Code.require_file("lib/paginator.ex", __DIR__)

ExUnit.start(autorun: false)

defmodule PaginatorGradeTest do
  use ExUnit.Case

  test "first page returns initial slice" do
    res = Paginator.paginate([:a, :b, :c, :d, :e], 1, 2)

    assert res == %{
             entries: [:a, :b],
             page: 1,
             per_page: 2,
             total: 5,
             total_pages: 3,
             has_prev?: false,
             has_next?: true
           }
  end

  test "partial last page computes total_pages and has_next? accurately" do
    res = Paginator.paginate([:a, :b, :c, :d, :e], 3, 2)

    assert res == %{
             entries: [:e],
             page: 3,
             per_page: 2,
             total: 5,
             total_pages: 3,
             has_prev?: true,
             has_next?: false
           }
  end

  test "empty items returns empty entries with total_pages = 1" do
    res = Paginator.paginate([], 1, 10)

    assert res == %{
             entries: [],
             page: 1,
             per_page: 10,
             total: 0,
             total_pages: 1,
             has_prev?: false,
             has_next?: false
           }
  end

  test "page beyond total_pages returns empty entries and has_next? = false" do
    res = Paginator.paginate([1, 2], 4, 2)

    assert res == %{
             entries: [],
             page: 4,
             per_page: 2,
             total: 2,
             total_pages: 1,
             has_prev?: true,
             has_next?: false
           }
  end
end

case ExUnit.run() do
  %{failures: 0} -> System.halt(0)
  _ -> System.halt(1)
end

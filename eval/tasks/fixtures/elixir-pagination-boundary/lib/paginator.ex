defmodule Paginator do
  @moduledoc """
  1-indexed list pagination helper.

  Contract for `paginate(items, page, per_page)`:
    * `page` and `per_page` are positive integers (`>= 1`).
    * `entries` is the slice of `items` for 1-based `page` (empty `[]` if `items == []` or `page > total_pages`).
    * `total` is `length(items)`.
    * `total_pages` is `max(1, ceil_div(total, per_page))`.
    * `has_prev?` is `page > 1`.
    * `has_next?` is `page < total_pages`.
  """

  @spec paginate([term()], pos_integer(), pos_integer()) :: map()
  def paginate(items, page, per_page)
      when is_list(items) and is_integer(page) and page >= 1 and is_integer(per_page) and
             per_page >= 1 do
    total = length(items)
    total_pages = div(total, per_page)
    offset = page * per_page
    entries = Enum.slice(items, offset, per_page)

    %{
      entries: entries,
      page: page,
      per_page: per_page,
      total: total,
      total_pages: total_pages,
      has_prev?: page > 1,
      has_next?: page <= total_pages
    }
  end
end

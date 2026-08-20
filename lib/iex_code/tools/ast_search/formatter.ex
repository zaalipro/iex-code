defmodule IexCode.Tools.ASTSearch.Formatter do
  @moduledoc """
  Output formatter for ASTSearch results.
  """

  alias IexCode.Tools.ASTSearch.Extractor

  @doc """
  Formats a single symbol entry into a readable location string.
  """
  @spec format_symbol(Extractor.symbol_entry()) :: String.t()
  def format_symbol(entry) do
    loc = "#{entry.file}:#{entry.line}"

    type_tag =
      cond do
        entry.type in [:module, :defmodule] -> "[module]"
        entry.type in [:function, :def, :defp] -> "[function]"
        entry.type in [:macro, :defmacro, :defmacrop] -> "[macro]"
        true -> "[#{entry.type}]"
      end

    name_str =
      cond do
        entry.type in [:module, :defmodule] ->
          entry.name

        entry.type in [:function, :def, :defp, :macro, :defmacro, :defmacrop, :spec, :callback] and
            entry.arity != nil ->
          mod = if entry.module, do: "#{entry.module}.", else: ""
          "#{mod}#{entry.name}/#{entry.arity}"

        true ->
          mod = if entry.module, do: "#{entry.module}.", else: ""
          "#{mod}#{entry.name}"
      end

    vis = if entry.visibility == :private, do: " (private)", else: ""

    "#{loc} #{type_tag} #{name_str}#{vis}"
  end

  @doc """
  Formats a list of symbol entries with optional code snippets.
  """
  @spec format_results([Extractor.symbol_entry()], keyword()) :: String.t()
  def format_results(entries, opts \\ [])
  def format_results([], _opts), do: "No AST symbols found matching query."

  def format_results(entries, opts) do
    include_code? = Keyword.get(opts, :include_code, false)

    entries
    |> Enum.map(fn entry ->
      header = format_symbol(entry)

      if include_code? and entry.code do
        "#{header}\n  " <> String.replace(entry.code, "\n", "\n  ")
      else
        header
      end
    end)
    |> Enum.join("\n")
  end
end

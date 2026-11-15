defmodule AstRenamer do
  @moduledoc """
  AST-aware Elixir function renaming utility.
  """

  @spec rename_function(String.t(), atom(), atom(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def rename_function(source, old_name, new_name, arity)
      when is_binary(source) and is_atom(old_name) and is_atom(new_name) and
             is_integer(arity) and arity >= 0 do
    # BUG: naive regex replacement corrupts strings, atoms, variables, and other arities,
    # and ignores syntax errors in source.
    pattern = ~r/\b#{Regex.escape(Atom.to_string(old_name))}\b/
    {:ok, String.replace(source, pattern, Atom.to_string(new_name))}
  end
end

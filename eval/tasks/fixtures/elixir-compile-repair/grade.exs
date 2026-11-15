Code.require_file("lib/slugifier.ex", __DIR__)

ExUnit.start(autorun: false)

defmodule SlugifierGradeTest do
  use ExUnit.Case

  test "normalizes punctuation, spaces, and case into clean slugs" do
    assert Slugifier.slugify("Hello, World!") == "hello-world"
    assert Slugifier.slugify("  IexCode -- Eval   Suite 2026! ") == "iexcode-eval-suite-2026"
    assert Slugifier.slugify("---already_clean---") == "already-clean"
    assert Slugifier.slugify("!!!") == ""
  end
end

case ExUnit.run() do
  %{failures: 0} -> System.halt(0)
  _ -> System.halt(1)
end

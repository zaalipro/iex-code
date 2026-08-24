defmodule IexCode.Research.RegistryTest do
  use ExUnit.Case, async: true

  alias IexCode.Research.Registry

  test "every registered provider exposes a complete descriptor matching its module" do
    descriptors = Registry.descriptors()

    assert Enum.map(descriptors, & &1.id) == Registry.names()
    assert length(descriptors) == map_size(Registry.all())

    for descriptor <- descriptors do
      assert descriptor.lifecycle in [:active, :legacy, :retired, :unofficial]
      assert is_binary(descriptor.auth_label) and descriptor.auth_label != ""
      assert :web_search in descriptor.capabilities
      assert {:ok, descriptor.module} == Registry.fetch(descriptor.id)
      assert descriptor.module.name() == descriptor.id
    end
  end

  test "descriptor aliases and provider lifecycle labels remain explicit" do
    assert {:ok, %{id: :bing, lifecycle: :retired}} = Registry.descriptor(:bing)
    refute Registry.automatically_selectable?("bing")

    assert {:ok, %{id: :google, lifecycle: :legacy}} = Registry.descriptor("google_cse")
    assert Registry.automatically_selectable?(:google)

    assert {:ok, %{id: :duckduckgo, lifecycle: :unofficial, auth_label: "No credentials"}} =
             Registry.descriptor("duckduckgo")

    assert Registry.automatically_selectable?(:duckduckgo)
    assert :error = Registry.descriptor("unknown")
  end

  test "descriptor metadata does not close the registry to custom provider modules" do
    provider = IexCode.TestResearchSearchStub
    assert Registry.automatically_selectable?(provider)

    assert [{^provider, ^provider, %{enabled: true}}] =
             Registry.configured(%{provider => %{enabled: true}})
  end
end

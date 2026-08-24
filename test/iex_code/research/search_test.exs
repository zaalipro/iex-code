defmodule IexCode.Research.SearchTest do
  use ExUnit.Case, async: true

  alias IexCode.Research.{Registry, Search}

  test "runs enabled atom/string providers, deduplicates URLs, and retains partial errors" do
    request = fn opts ->
      case opts[:url] do
        "https://html.duckduckgo.com/html/" ->
          {:ok,
           %{
             status: 200,
             body:
               "<div class='result'><a class='result__a' href='https://same.test/path/'>One</a><span class='result__snippet'>first</span></div>"
           }}

        "https://google.serper.dev/search" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "organic" => [
                 %{
                   "title" => "Duplicate",
                   "link" => "https://same.test/path",
                   "snippet" => "second"
                 },
                 %{"title" => "Two", "link" => "https://other.test", "snippet" => "other"}
               ]
             }
           }}
      end
    end

    config = %{"serper" => %{"api_key" => "key"}}

    assert {:ok, response} =
             Search.search("beam",
               providers: [:duckduckgo, "serper", :tavily],
               config: config,
               request: request
             )

    assert Enum.map(response.results, & &1.url) == [
             "https://same.test/path/",
             "https://other.test"
           ]

    assert response.errors == %{"tavily" => :missing_api_key}
    assert response.providers == ["duckduckgo", "serper"]
  end

  test "reports all-provider failure and validates selection" do
    assert {:error, :invalid_query} = Search.search("  ")
    assert {:error, :no_providers} = Search.search("query", providers: [:unknown])

    assert {:error,
            {:all_providers_failed, %{"brave" => :missing_api_key, "tavily" => :missing_api_key}}} =
             Search.search("query", providers: [:brave, :tavily])
  end

  test "provider configuration unwraps settings-shaped maps and honors enabled flags" do
    config = %{
      search_providers: %{
        "duckduckgo" => %{"enabled" => false},
        "brave" => %{"enabled" => true, "api_key" => "key"}
      }
    }

    assert [{:brave, IexCode.Research.Providers.Brave, provider_config}] =
             Registry.configured_providers(config)

    assert provider_config["api_key"] == "key"
  end
end

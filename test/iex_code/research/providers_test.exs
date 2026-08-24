defmodule IexCode.Research.ProvidersTest do
  use ExUnit.Case, async: true

  alias IexCode.Research.HTTP

  alias IexCode.Research.Providers.{
    Bing,
    Brave,
    DuckDuckGo,
    Exa,
    GoogleCSE,
    SearxNG,
    Serper,
    Tavily
  }

  test "Tavily maps its response and sends credentials in JSON" do
    request = fn opts ->
      assert opts[:method] == :post
      assert opts[:url] == "https://api.tavily.com/search"
      assert opts[:json].api_key == "secret"

      {:ok,
       %{
         status: 200,
         body: %{
           "results" => [
             %{"title" => "T", "url" => "https://t.test", "content" => "S", "score" => 0.8}
           ]
         }
       }}
    end

    assert {:ok, [result]} = Tavily.search("elixir", api_key: "secret", request: request)
    assert result.provider == "tavily"
    assert result.score == 0.8
  end

  test "provider HTTP failures redact configured credentials" do
    request = fn _opts ->
      {:ok, %{status: 401, body: %{"message" => "invalid secret-value"}}}
    end

    assert {:error, {:http_error, 401, body}} =
             Brave.search("query", api_key: "secret-value", request: request)

    assert body["message"] == "invalid [REDACTED]"
    refute inspect(body) =~ "secret-value"
  end

  test "normalizes bounded streamed Req responses from the production response shape" do
    request = fn opts ->
      assert opts[:redirect] == false
      assert opts[:retry] == false
      assert opts[:decode_body] == false
      assert opts[:compressed] == false
      assert is_function(opts[:into], 2)

      req = Req.new()
      response = Req.Response.new(status: 200, headers: %{"content-type" => ["application/json"]})

      assert {:cont, {^req, response}} =
               opts[:into].(
                 {:data, ~s({"results":[{"title":"T","url":"https://t.test","content":"S"}]})},
                 {req, response}
               )

      {:ok, response}
    end

    assert {:ok, [result]} =
             Tavily.search("elixir",
               api_key: "secret",
               redirect: true,
               retry: true,
               decode_body: true,
               compressed: true,
               into: :self,
               request: request
             )

    assert result.url == "https://t.test"
  end

  test "enforces the body cap for streamed and injected map responses" do
    streamed = fn opts ->
      req = Req.new()
      response = Req.Response.new(status: 200)
      chunk = :binary.copy("x", 2_000_001)
      assert {:halt, {^req, response}} = opts[:into].({:data, chunk}, {req, response})
      {:ok, response}
    end

    assert {:error, :response_too_large} =
             HTTP.request(:get, "https://example.test", request: streamed)

    injected = fn _opts ->
      {:ok, %{status: 200, body: :binary.copy("x", 2_000_001)}}
    end

    assert {:error, :response_too_large} =
             HTTP.request(:get, "https://example.test", request: injected)
  end

  test "bounds keyless errors and sanitizes rescue and catch paths" do
    long_error = fn _opts -> {:error, :binary.copy("x", 10_000)} end
    assert {:error, reason} = HTTP.request(:get, "https://example.test", request: long_error)
    assert byte_size(reason) == 4_000

    raising = fn _opts -> raise "credential secret-value failed" end

    assert {:error, {:request_exception, message}} =
             HTTP.request(:get, "https://example.test",
               api_key: "secret-value",
               request: raising
             )

    assert message == "credential [REDACTED] failed"

    throwing = fn _opts -> throw(:binary.copy("y", 10_000)) end

    assert {:error, {:request_failure, :throw, caught}} =
             HTTP.request(:get, "https://example.test", request: throwing)

    assert byte_size(caught) == 4_000

    oversized_map = fn _opts ->
      body = Map.new(1..100, &{"key-#{&1}", :binary.copy("z", 5_000)})
      {:ok, %{status: 500, body: body}}
    end

    assert {:error, {:http_error, 500, body}} =
             HTTP.request(:get, "https://example.test", request: oversized_map)

    assert map_size(body) == 50
    assert Enum.all?(body, fn {_key, value} -> byte_size(value) == 4_000 end)
  end

  test "official providers reject changed origins while custom SearxNG remains injectable" do
    assert_raise ArgumentError, fn ->
      Brave.search("query",
        api_key: "key",
        base_url: "https://attacker.test",
        request: fn _opts -> flunk("request must not be issued") end
      )
    end

    request = fn opts ->
      assert opts[:url] == "https://search.example.test/search"
      {:ok, %{status: 200, body: %{"results" => []}}}
    end

    assert {:ok, []} =
             SearxNG.search("query",
               base_url: "https://search.example.test",
               request: request
             )
  end

  test "all authenticated JSON adapters normalize representative payloads" do
    cases = [
      {Brave,
       %{
         "web" => %{
           "results" => [%{"title" => "B", "url" => "https://b.test", "description" => "brave"}]
         }
       }},
      {Exa, %{"results" => [%{"title" => "E", "url" => "https://e.test", "text" => "exa"}]}},
      {Serper,
       %{"organic" => [%{"title" => "S", "link" => "https://s.test", "snippet" => "serper"}]}},
      {Bing,
       %{
         "webPages" => %{
           "value" => [%{"name" => "Bi", "url" => "https://bi.test", "snippet" => "bing"}]
         }
       }}
    ]

    for {module, body} <- cases do
      request = fn _opts -> {:ok, %{status: 200, body: body}} end
      assert {:ok, [result]} = module.search("query", api_key: "key", request: request)
      assert result.provider == to_string(module.name())
      assert String.starts_with?(result.url, "https://")
    end
  end

  test "Google CSE requires both key and engine identifier" do
    assert {:error, :missing_api_key} = GoogleCSE.search("query", [])
    assert {:error, :missing_cx} = GoogleCSE.search("query", api_key: "key")

    request = fn _opts ->
      {:ok,
       %{
         status: 200,
         body: %{
           "items" => [%{"title" => "G", "link" => "https://g.test", "snippet" => "google"}]
         }
       }}
    end

    assert {:ok, [result]} =
             GoogleCSE.search("query", api_key: "key", cx: "engine", request: request)

    assert result.provider == "google"
  end

  test "SearxNG requires an instance and parses JSON results" do
    assert {:error, :missing_base_url} = SearxNG.search("query", [])

    request = fn opts ->
      assert opts[:url] == "https://search.internal/search"

      {:ok,
       %{
         status: 200,
         body: %{"results" => [%{"title" => "X", "url" => "https://x.test", "content" => "meta"}]}
       }}
    end

    assert {:ok, [result]} =
             SearxNG.search("query", base_url: "https://search.internal", request: request)

    assert result.provider == "searxng"
  end

  test "DuckDuckGo parses HTML results and unwraps redirect links" do
    html = """
    <div class="result">
      <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Farticle">Article</a>
      <div class="result__snippet">A useful article</div>
    </div>
    """

    request = fn opts ->
      assert opts[:form] == [q: "query"]
      {:ok, %{status: 200, body: html}}
    end

    assert {:ok, [result]} = DuckDuckGo.search("query", request: request)
    assert result.url == "https://example.com/article"
    assert result.snippet == "A useful article"
  end
end

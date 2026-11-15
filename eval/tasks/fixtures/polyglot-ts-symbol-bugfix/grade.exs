ExUnit.start(autorun: false)

defmodule PolyglotTsSymbolBugfixGradeTest do
  use ExUnit.Case

  @ts_path Path.join(__DIR__, "src/symbol_resolver.ts")

  test "SymbolTable and formatSymbolSignature pass all behavioral assertions" do
    source = File.read!(@ts_path)

    # Structural sanity checks
    assert source =~ "export interface SymbolEntry"
    assert source =~ "export class SymbolTable"
    assert source =~ "export function formatSymbolSignature"

    case System.find_executable("node") do
      nil ->
        # Portable Elixir AST/pattern fallback when Node.js is absent
        refute source =~ "key.includes("
        refute source =~ "this.entries.set(target,"
        assert source =~ ~r/namespace\s*\?\s*`\$\{.*namespace\}\.\$\{.*name\}`/
        assert source =~ ~r/\.join\(\s*["'],\s*["']\s*\)/
        assert source =~ ~r/:\s*\$\{.*returnType\}/

      node_bin ->
        {strip_supported?, ext, args_prefix, code_body} =
          case System.cmd(
                 node_bin,
                 ["--no-warnings", "--experimental-strip-types", "-e", "const x: number = 1;"],
                 stderr_to_stdout: true
               ) do
            {_, 0} -> {true, ".mts", ["--no-warnings", "--experimental-strip-types"], source}
            _ -> {false, ".mjs", [], transpile_ts_module(source)}
          end

        _ = strip_supported?

        tmp_js =
          Path.join(
            System.tmp_dir!(),
            "symbol_resolver_#{System.unique_integer([:positive])}#{ext}"
          )

        try do
          harness = """
          import assert from "node:assert/strict";

          #{code_body}

          const table = new SymbolTable();
          table.register({
            name: "login",
            kind: "function",
            namespace: "Auth",
            params: ["user", "pass"],
            returnType: "Promise<boolean>"
          });
          table.register({
            name: "login",
            kind: "function",
            namespace: "Admin",
            params: ["token"],
            returnType: "boolean"
          });
          table.register({
            name: "getUser",
            kind: "function",
            params: ["id"],
            returnType: "User"
          });

          assert.equal(table.size(), 3);

          const authLogin = table.resolve("login", "Auth");
          const adminLogin = table.resolve("login", "Admin");
          assert.equal(authLogin?.namespace, "Auth");
          assert.equal(adminLogin?.namespace, "Admin");
          assert.deepEqual(authLogin?.params, ["user", "pass"]);

          // Must not collide on substring ("get" vs "getUser") or mutate size on miss
          assert.equal(table.resolve("get"), undefined);
          assert.equal(table.resolve("login", "Billing"), undefined);
          assert.equal(table.size(), 3);

          assert.equal(table.resolve("getUser")?.name, "getUser");

          assert.equal(
            formatSymbolSignature(authLogin),
            "function Auth.login(user, pass): Promise<boolean>"
          );
          assert.equal(
            formatSymbolSignature({ name: "ping", kind: "method", params: [] }),
            "method ping()"
          );
          assert.equal(
            formatSymbolSignature({ name: "UserId", kind: "type", namespace: "Core", returnType: "string" }),
            "type Core.UserId(): string"
          );
          """

          File.write!(tmp_js, harness)

          {output, exit_code} =
            System.cmd(node_bin, args_prefix ++ [tmp_js], stderr_to_stdout: true)

          assert exit_code == 0, "Node test failed:\n#{output}"
        after
          File.rm(tmp_js)
        end
    end
  end

  defp transpile_ts_module(source) do
    source
    |> strip_ts_interfaces()
    |> String.replace(
      ~r/private\s+entries:\s*Map<[^>]+>\s*=\s*new Map\(\);/,
      "entries = new Map();"
    )
    |> String.replace(~r/register\(entry:\s*SymbolEntry\):\s*void\s*\{/, "register(entry) {")
    |> String.replace(
      ~r/resolve\(name:\s*string,\s*namespace\?:\s*string\):\s*SymbolEntry\s*\|\s*undefined\s*\{/,
      "resolve(name, namespace) {"
    )
    |> String.replace(~r/size\(\):\s*number\s*\{/, "size() {")
    |> String.replace(
      ~r/formatSymbolSignature\(entry:\s*SymbolEntry\):\s*string\s*\{/,
      "formatSymbolSignature(entry) {"
    )
  end

  defp strip_ts_interfaces(source) do
    Regex.replace(~r/export\s+interface\s+\w+\s*\{[^}]*\}\s*/s, source, "")
  end
end

case ExUnit.run() do
  %{failures: 0} -> System.halt(0)
  _ -> System.halt(1)
end

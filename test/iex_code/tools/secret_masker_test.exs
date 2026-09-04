defmodule IexCode.Tools.SecretMaskerTest do
  use IexCode.DataCase, async: false
  alias IexCode.Tools
  alias IexCode.Tools.SecretMasker

  describe "scrub/2" do
    test "redacts known secrets from output" do
      known = ["my-super-secret-token-value-99"]
      raw = "Connected with token: my-super-secret-token-value-99 successfully."

      scrubbed = SecretMasker.scrub(raw, known)
      assert scrubbed == "Connected with token: [REDACTED_SECRET] successfully."
    end

    test "redacts OpenAI API key pattern" do
      raw = "Using key sk-proj-abcdef1234567890abcdef1234567890"
      scrubbed = SecretMasker.scrub(raw)
      assert scrubbed == "Using key [REDACTED_SECRET]"
    end

    test "redacts Anthropic API key pattern" do
      raw = "Using key sk-ant-api03-abcdef1234567890abcdef1234567890"
      scrubbed = SecretMasker.scrub(raw)
      assert scrubbed == "Using key [REDACTED_SECRET]"
    end

    test "redacts GitHub personal access tokens" do
      raw = "git clone https://ghp_1234567890abcdef1234567890abcdef1234@github.com/repo"
      scrubbed = SecretMasker.scrub(raw)
      assert scrubbed =~ "[REDACTED_SECRET]"
      refute scrubbed =~ "ghp_1234567890"
    end

    test "redacts Bearer authorization header tokens" do
      raw = "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
      scrubbed = SecretMasker.scrub(raw)
      assert scrubbed == "Authorization: Bearer [REDACTED_SECRET]"
    end

    test "redacts sensitive env assignments in output" do
      raw = "DATABASE_URL=postgres://user:pass@localhost:5432/db\nAPI_KEY=secret_value_123\n"
      scrubbed = SecretMasker.scrub(raw)
      assert scrubbed =~ "DATABASE_URL=[REDACTED_SECRET]"
      assert scrubbed =~ "API_KEY=[REDACTED_SECRET]"
    end

    test "handles nil or non-binary input safely" do
      assert SecretMasker.scrub(nil) == ""
      assert SecretMasker.scrub(123) == "123"
    end
  end

  describe "build_sandbox_env/3" do
    test "isolated mode contains only base variables and custom vars" do
      custom_vars = %{"MY_CUSTOM_TEST_VAR" => "custom_val"}
      env = SecretMasker.build_sandbox_env("isolated", custom_vars, "/test/workspace")

      assert env["MY_CUSTOM_TEST_VAR"] == "custom_val"
      assert env["WORKSPACE_ROOT"] == "/test/workspace"
      refute Map.has_key?(env, "OPENAI_API_KEY")
      refute Map.has_key?(env, "ANTHROPIC_API_KEY")
    end

    test "inherit_filtered mode strips keys with sensitive keywords" do
      # Set temporary env var
      System.put_env("TEST_RUN_SECRET_KEY", "sensitive_val")
      System.put_env("TEST_SAFE_VAR", "safe_val")

      on_exit(fn ->
        System.delete_env("TEST_RUN_SECRET_KEY")
        System.delete_env("TEST_SAFE_VAR")
      end)

      env = SecretMasker.build_sandbox_env("inherit_filtered", %{}, "/test/workspace")

      assert env["TEST_SAFE_VAR"] == "safe_val"
      refute Map.has_key?(env, "TEST_RUN_SECRET_KEY")
    end

    test "to_port_env/1 converts string map to charlist tuple list" do
      env_map = %{"FOO" => "bar", "NUM" => 123}
      port_env = SecretMasker.to_port_env(env_map)

      assert is_list(port_env)
      assert {~c"FOO", ~c"bar"} in port_env
      assert {~c"NUM", ~c"123"} in port_env
    end
  end

  describe "run_command execution with sandbox and masking" do
    test "injects custom environment variables into subshell execution" do
      args = %{
        "command" => "echo \"VAL=$MY_INJECTED_TEST_VAR\"",
        "env" => %{"MY_INJECTED_TEST_VAR" => "parity_verified_42"}
      }

      assert {:ok, output} = Tools.execute("run_command", args, File.cwd!())
      assert output =~ "VAL=parity_verified_42"
    end

    test "scrubs known secret when printed in command output" do
      secret = "super_classified_secret_pass_123"

      args = %{
        "command" => "echo \"Output with secret: #{secret}\"",
        "__settings__" => %IexCode.Settings.AppSettings{
          custom_env_vars: %{"S_KEY" => secret}
        }
      }

      assert {:ok, output} = Tools.execute("run_command", args, File.cwd!())
      assert output =~ "[REDACTED_SECRET]"
      refute output =~ secret
    end
  end
end

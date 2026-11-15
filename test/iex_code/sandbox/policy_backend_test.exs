defmodule IexCode.Sandbox.PolicyBackendTest do
  use ExUnit.Case, async: true

  alias IexCode.Sandbox.{Backend, Policy}

  test "parses policies with defaults" do
    assert {:ok, policy} = Policy.from_map(%{})
    assert policy.reads == ["/"]
    assert policy.writes == []
    assert policy.network == :deny
    assert policy.strict == true

    assert {:ok, custom} =
             Policy.from_map(%{
               "reads" => ["/usr"],
               "writes" => ["/tmp/w"],
               "network" => "allow",
               "strict" => false
             })

    assert custom.network == :allow
    assert custom.strict == false
  end

  test "rejects bad policy fields" do
    assert {:error, {:sandbox_policy_field, "network"}} = Policy.from_map(%{"network" => "maybe"})
    assert {:error, {:sandbox_policy_field, "reads"}} = Policy.from_map(%{"reads" => "nope"})
    assert {:error, :sandbox_policy_shape} = Policy.from_map("nope")
  end

  test "prefix checks respect hierarchy" do
    policy = Policy.for_workdir("/tmp/work")

    assert Policy.allows_read?(policy, "/tmp/work/a.txt")
    assert Policy.allows_write?(policy, "/tmp/work/a.txt")
    assert Policy.allows_read?(policy, "/etc/hosts")
    refute Policy.allows_write?(policy, "/etc/hosts")
    refute Policy.allows_write?(policy, "/tmp/workother/a.txt")
  end

  test "detect returns a known backend" do
    assert Backend.detect() in [:bwrap, :sandbox_exec, :none]
  end

  test "bwrap wrapping denies network and binds prefixes" do
    policy = %Policy{reads: ["/usr"], writes: ["/tmp/w"], network: :deny, strict: true}

    assert {:ok, argv} = Backend.wrap(:bwrap, ["sh", "-c", "echo hi"], policy, [])
    assert "--unshare-net" in argv
    assert "--ro-bind" in argv
    assert "/tmp/w" in argv
    assert List.last(argv) == "echo hi"
    assert "--" in argv
  end

  test "sandbox-exec needs a profile path" do
    policy = %Policy{}

    assert {:error, :sandbox_profile_required} =
             Backend.wrap(:sandbox_exec, ["echo"], policy, [])

    assert {:ok, ["sandbox-exec", "-f", "/p.sb", "echo"]} =
             Backend.wrap(:sandbox_exec, ["echo"], policy, profile_path: "/p.sb")
  end

  test "seatbelt profile encodes policy" do
    policy = %Policy{reads: ["/data"], writes: ["/tmp/w"], network: :deny, strict: true}
    profile = Backend.seatbelt_profile(policy)

    assert profile =~ "(deny default)"
    assert profile =~ ~s|(allow file-read* (subpath "/data"))|
    assert profile =~ ~s|(allow file-write* (subpath "/tmp/w"))|
    assert profile =~ "(deny network*)"
  end

  test "empty commands and missing backends error" do
    assert {:error, :sandbox_empty_command} = Backend.wrap(:bwrap, [], %Policy{}, [])
    assert {:error, :no_sandbox_backend} = Backend.wrap(:none, ["echo"], %Policy{}, [])
  end

  test "seatbelt profile removes (with no-sandbox), allows confined exec/fork, and expands /tmp and /var on macOS" do
    policy = %Policy{reads: ["/tmp/r"], writes: ["/var/w"], network: :deny, strict: true}
    profile = Backend.seatbelt_profile(policy)

    assert profile =~ "(allow process-exec)"
    assert profile =~ "(allow process-fork)"
    refute profile =~ "(with no-sandbox)"
    refute profile =~ "no-sandbox"

    if match?({:unix, :darwin}, :os.type()) do
      assert profile =~ ~s|(allow file-read* (subpath "/private/tmp/r"))|
      assert profile =~ ~s|(allow file-write* (subpath "/private/var/w"))|
    end
  end

  test "seatbelt escaping handles backslashes before quotes and rejects NUL/newline/empty injection" do
    policy = %Policy{reads: [~S(/a\b"c)], writes: [~S(/d\"e)], network: :deny}
    profile = Backend.seatbelt_profile(policy)

    assert profile =~ ~S|(subpath "/a\\b\"c")|
    assert profile =~ ~S|(subpath "/d\\\"e")|

    for bad <- ["", "/tmp/evil\n(allow default)", "/tmp/evil\r", "/tmp/evil\0path"] do
      assert {:error, {:sandbox_policy_field, "reads"}} =
               Policy.from_map(%{"reads" => [bad], "writes" => []})

      assert {:error, {:sandbox_policy_field, "writes"}} =
               Policy.from_map(%{"reads" => ["/"], "writes" => [bad]})

      assert_raise ArgumentError, fn ->
        Backend.seatbelt_profile(%Policy{reads: [bad], writes: []})
      end
    end
  end
end

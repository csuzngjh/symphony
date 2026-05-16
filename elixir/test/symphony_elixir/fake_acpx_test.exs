defmodule SymphonyElixir.FakeAcpxTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias SymphonyElixir.AgentRunner.AcpxSession

  describe "fake ACPX success mode" do
    setup do
      System.put_env("FAKE_ACPX_MODE", "success")
      on_exit(fn -> System.delete_env("FAKE_ACPX_MODE") end)
      :ok
    end

    test "emits JSON-RPC events and returns completed status" do
      {:ok, pid} =
        AcpxSession.start_link(name: :fake_acpx_success_test, agent: "claude", cwd: "/tmp")

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5000)
      end)

      {:ok, session_id} = AcpxSession.sessions_new(pid, "fake-success-test", "/tmp")
      assert is_binary(session_id) and session_id != ""

      {:ok, result} = AcpxSession.prompt(pid, "hello", [])

      assert result.status == "completed"
      assert result.output =~ "Hello from fake ACPX."
      assert result.output =~ "Task completed by fake ACPX."
      assert result.usage != nil
      assert result.usage["inputTokens"] == 100
      assert result.usage["outputTokens"] == 50
      assert result.usage["totalTokens"] == 150

      tool_call_events = Enum.filter(result.events, fn e -> e.type == :tool_call end)
      assert length(tool_call_events) == 1
    end
  end

  describe "default configuration" do
    test "ACPX_COMMAND resolves to fake_acpx.js fixture by default" do
      acpx_cmd = System.get_env("ACPX_COMMAND")
      assert acpx_cmd =~ "fixtures/fake_acpx.js"
    end
  end
end
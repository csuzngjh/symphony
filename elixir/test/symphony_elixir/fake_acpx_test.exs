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

      {:ok, _session_id} = AcpxSession.sessions_new(pid, "fake-success-test", "/tmp")
      {:ok, result} = AcpxSession.prompt(pid, "hello", [])

      assert result.status == "completed"
    end
  end

  describe "default configuration" do
    test "ACPX_COMMAND resolves to fake_acpx.js fixture by default" do
      acpx_cmd = System.get_env("ACPX_COMMAND")
      assert acpx_cmd =~ "fixtures/fake_acpx.js"
    end
  end
end
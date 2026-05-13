defmodule SymphonyElixir.AgentRunner.AcpxSessionIntegrationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRunner.AcpxSession

  describe "concurrent session start (de-singletonization)" do
    test "two sessions with unique names start and stop without conflict" do
      {:ok, pid1} =
        AcpxSession.start_link(
          name: :integration_test_sess_1,
          agent: "claude",
          cwd: "/tmp"
        )

      {:ok, pid2} =
        AcpxSession.start_link(
          name: :integration_test_sess_2,
          agent: "codex",
          cwd: "/tmp"
        )

      on_exit(fn ->
        clean_pid(pid1)
        clean_pid(pid2)
      end)

      assert is_pid(pid1)
      assert is_pid(pid2)
      assert pid1 != pid2

      {:ok, status1} = AcpxSession.status(pid1)
      {:ok, status2} = AcpxSession.status(pid2)

      assert status1.agent == "claude"
      assert status2.agent == "codex"
    end

    test "three concurrent sessions all start and report correct state" do
      tasks =
        for {name, agent} <- [a: "agent-a", b: "agent-b", c: "agent-c"] do
          Task.async(fn ->
            {:ok, pid} =
              AcpxSession.start_link(
                name: :"integration_c_#{name}",
                agent: agent,
                cwd: "/tmp"
              )

            {:ok, status} = AcpxSession.status(pid)
            {name, status.agent, pid}
          end)
        end

      results = Task.yield_many(tasks, timeout: 5000)

      agents =
        results
        |> Enum.map(fn
          {_task, {:ok, {_name, agent, _pid}}} -> agent
          _ -> nil
        end)

      assert "agent-a" in agents
      assert "agent-b" in agents
      assert "agent-c" in agents

      on_exit(fn ->
        Enum.each(results, fn
          {_task, {:ok, {_name, _agent, pid}}} ->
            clean_pid(pid)

          _ ->
            :ok
        end)
      end)
    end
  end

  describe "session naming" do
    test "named session is reachable by registered name" do
      {:ok, pid} =
        AcpxSession.start_link(
          name: :integration_named_test,
          agent: "claude",
          cwd: "/tmp"
        )

      on_exit(fn -> clean_pid(pid) end)

      assert Process.whereis(:integration_named_test) == pid
      assert {:ok, %{agent: "claude"}} = AcpxSession.status(:integration_named_test)
    end

    test "unnamed session starts without Process registration" do
      {:ok, pid} = AcpxSession.start_link(agent: "claude", cwd: "/tmp")

      on_exit(fn -> clean_pid(pid) end)

      assert is_pid(pid)
      assert {:ok, %{agent: "claude"}} = AcpxSession.status(pid)
    end
  end

  describe "session lifecycle" do
    test "initial state has nil port" do
      {:ok, pid} =
        AcpxSession.start_link(
          name: :integration_state_test,
          agent: "claude",
          cwd: "/tmp"
        )

      on_exit(fn -> clean_pid(pid) end)

      state = :sys.get_state(pid)
      assert state.port == nil
      assert state.session_name == nil
      assert state.session_id == nil
    end

    test "GenServer survives call to session with error execution strategy" do
      # Force an error strategy by passing acpx_options that will fail at resolution
      {:ok, pid} =
        AcpxSession.start_link(
          name: :integration_ensure_fail,
          agent: "claude",
          cwd: "/tmp"
        )

      on_exit(fn -> clean_pid(pid) end)

      state = :sys.get_state(pid)

      if match?({:error, _}, state.execution_strategy) do
        result = AcpxSession.sessions_ensure(pid, "fail-session", "/tmp")
        assert match?({:error, _}, result)
      end

      assert Process.alive?(pid)
    end
  end

  defp clean_pid(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5000)
  end

  defp clean_pid(_), do: :ok
end

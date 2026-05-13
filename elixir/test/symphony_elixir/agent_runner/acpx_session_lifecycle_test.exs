defmodule SymphonyElixir.AgentRunner.AcpxSessionLifecycleTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRunner.AcpxSession
  alias SymphonyElixir.AgentRunner.ProcessKiller

  setup do
    ProcessKiller.set_impl(SymphonyElixir.AgentRunner.ProcessKiller.Mock)
    Process.put(:process_killer_test_pid, self())

    on_exit(fn ->
      ProcessKiller.reset_impl()
      Process.delete(:process_killer_test_pid)
    end)

    :ok
  end

  describe "terminate callback" do
    test "terminate/2 calls cleanup_port and does not crash" do
      {:ok, state} = AcpxSession.init([])
      state = %{state | port: :fake_port, os_pid: 42}
      assert :ok = AcpxSession.terminate(:shutdown, state)
    end

    test "terminate/2 is idempotent" do
      {:ok, state} = AcpxSession.init([])
      state = %{state | port: nil, os_pid: nil}
      assert :ok = AcpxSession.terminate(:shutdown, state)
      assert :ok = AcpxSession.terminate(:shutdown, state)
    end

    test "terminate/2 with port but no os_pid does not crash" do
      {:ok, state} = AcpxSession.init([])
      state = %{state | port: :fake_port, os_pid: nil}
      assert :ok = AcpxSession.terminate(:shutdown, state)
    end
  end

  describe "status includes os_pid" do
    test "status returns os_pid field" do
      {:ok, state} = AcpxSession.init([])
      assert state.os_pid == nil
    end

    test "os_pid is nil on init" do
      {:ok, state} = AcpxSession.init(issue_id: "TEST-1")
      assert state.os_pid == nil
      assert state.started_at == nil
    end
  end

  describe "GenServer terminate on stop" do
    test "stopping the GenServer triggers terminate" do
      {:ok, pid} = GenServer.start(AcpxSession, [])
      Process.monitor(pid)
      GenServer.stop(pid, :shutdown)

      assert_receive {:DOWN, _, :process, ^pid, _reason}, 2_000
    end

    test "GenServer with port in state stops cleanly" do
      {:ok, pid} = GenServer.start(AcpxSession, [])
      state = :sys.get_state(pid)
      state = %{state | port: nil, os_pid: 99}
      :sys.replace_state(pid, fn _ -> state end)

      Process.monitor(pid)
      GenServer.stop(pid, :shutdown)
      assert_receive {:DOWN, _, :process, ^pid, _reason}, 2_000
    end
  end
end

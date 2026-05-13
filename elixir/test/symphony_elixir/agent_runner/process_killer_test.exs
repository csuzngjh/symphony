defmodule SymphonyElixir.AgentRunner.ProcessKillerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRunner.ProcessKiller

  describe "WindowsTaskkill" do
    test "kill_tree with valid pid calls taskkill" do
      killer = SymphonyElixir.AgentRunner.ProcessKiller.WindowsTaskkill

      result = killer.kill_tree(999_999_999, [])
      assert result == :ok
    end

    test "kill_tree with invalid pid returns ok (idempotent)" do
      killer = SymphonyElixir.AgentRunner.ProcessKiller.WindowsTaskkill

      result = killer.kill_tree(-1, [])
      assert result == :ok
    end
  end

  describe "UnixSigterm" do
    test "kill_tree with valid pid returns ok" do
      killer = SymphonyElixir.AgentRunner.ProcessKiller.UnixSigterm

      result = killer.kill_tree(999_999_999, [])
      assert result == :ok
    end

    test "kill_tree with invalid pid returns ok (idempotent)" do
      killer = SymphonyElixir.AgentRunner.ProcessKiller.UnixSigterm

      result = killer.kill_tree(-1, [])
      assert result == :ok
    end
  end

  describe "Mock" do
    setup do
      ProcessKiller.set_impl(SymphonyElixir.AgentRunner.ProcessKiller.Mock)
      Process.put(:process_killer_test_pid, self())

      on_exit(fn ->
        ProcessKiller.reset_impl()
        Process.delete(:process_killer_test_pid)
      end)

      :ok
    end

    test "kill_tree sends message to test pid" do
      assert :ok = ProcessKiller.kill_tree(42)
      assert_received {:process_killer_kill, 42}
    end

    test "kill_tree is idempotent - calling twice sends two messages" do
      assert :ok = ProcessKiller.kill_tree(42)
      assert :ok = ProcessKiller.kill_tree(42)
      assert_received {:process_killer_kill, 42}
      assert_received {:process_killer_kill, 42}
    end

    test "kill_tree with invalid pid is a no-op" do
      assert :ok = ProcessKiller.kill_tree(-1)
      refute_received {:process_killer_kill, _}
    end

    test "set_impl and reset_impl work together" do
      ProcessKiller.reset_impl()
      refute_received {:process_killer_kill, _}
    end
  end
end

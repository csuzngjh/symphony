defmodule SymphonyElixir.OrchestratorPrFlowTest do
  use SymphonyElixir.TestSupport

  defp setup_completion_report(workspace_path, files \\ ["lib/example.ex"]) do
    completion_dir = Path.join(workspace_path, ".symphony")
    File.mkdir_p!(completion_dir)

    completion_content = Jason.encode!(%{
      "status" => "ready_for_review",
      "changed_files" => files,
      "tests" => [%{"command" => "mix test", "result" => "pass"}]
    })

    File.write!(Path.join(completion_dir, "agent-completion.json"), completion_content)
  end

  test "normal agent exit runs control-plane commit, push, PR, and tracker transition" do
    parent = self()
    issue_id = "issue-control-plane-pr"
    ref = make_ref()
    worker_pid = self()
    workspace_path = Path.join(System.tmp_dir!(), "symphony_orch_pr_flow_test")
    File.rm_rf!(workspace_path)
    File.mkdir_p!(workspace_path)
    setup_completion_report(workspace_path)

    command_runner = fn cmd, args, opts ->
      send(parent, {:command, cmd, args, opts})

      case {cmd, args} do
        {"git", ["status", "--porcelain"]} -> {" M lib/example.ex\n", 0}
        {"git", ["add", "--", "lib/example.ex"]} -> {"", 0}
        {"git", ["commit", "-m", _message]} -> {"committed", 0}
        {"git", ["rev-parse", "HEAD"]} -> {"abc123\n", 0}
        {"git", ["push", "-u", "origin", "symphony/pri-170-owned-pr"]} -> {"pushed", 0}
        {"gh", ["pr", "create" | _rest]} -> {"https://github.com/acme/repo/pull/170\n", 0}
      end
    end

    Application.put_env(:symphony_elixir, :pr_flow_command_runner, command_runner)
    Application.put_env(:symphony_elixir, :pr_flow_tracker_update, fn tracker_issue_id, state_name ->
      send(parent, {:tracker_update, tracker_issue_id, state_name})
      :ok
    end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :pr_flow_command_runner)
      Application.delete_env(:symphony_elixir, :pr_flow_tracker_update)
    end)

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :SuccessOrchestrator))

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    put_running_entry(pid, issue_id, ref, worker_pid, %{
      branch_name: "symphony/pri-170-owned-pr",
      workspace_path: workspace_path
    })

    send(pid, {:DOWN, ref, :process, worker_pid, :normal})

    assert_receive {:tracker_update, ^issue_id, "In Review"}, 1_000
    assert_receive {:command, "gh", ["pr", "create" | _], _}, 1_000

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.running == []
    assert snapshot.retrying == []
    assert snapshot.blocked == []
  end

  test "push failure blocks the issue and does not update tracker state" do
    parent = self()
    issue_id = "issue-control-plane-push-fail"
    ref = make_ref()
    worker_pid = self()
    workspace_path = Path.join(System.tmp_dir!(), "symphony_orch_pr_flow_push_test")
    File.rm_rf!(workspace_path)
    File.mkdir_p!(workspace_path)
    setup_completion_report(workspace_path)

    command_runner = fn cmd, args, opts ->
      send(parent, {:command, cmd, args, opts})

      case {cmd, args} do
        {"git", ["status", "--porcelain"]} -> {" M lib/example.ex\n", 0}
        {"git", ["add", "--", "lib/example.ex"]} -> {"", 0}
        {"git", ["commit", "-m", _message]} -> {"committed", 0}
        {"git", ["rev-parse", "HEAD"]} -> {"abc123\n", 0}
        {"git", ["push", "-u", "origin", "symphony/pri-170-owned-pr"]} -> {"network failed", 1}
      end
    end

    Application.put_env(:symphony_elixir, :pr_flow_command_runner, command_runner)
    Application.put_env(:symphony_elixir, :pr_flow_tracker_update, fn tracker_issue_id, state_name ->
      send(parent, {:tracker_update, tracker_issue_id, state_name})
      :ok
    end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :pr_flow_command_runner)
      Application.delete_env(:symphony_elixir, :pr_flow_tracker_update)
    end)

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :PushFailOrchestrator))

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    put_running_entry(pid, issue_id, ref, worker_pid, %{
      branch_name: "symphony/pri-170-owned-pr",
      workspace_path: workspace_path
    })

    send(pid, {:DOWN, ref, :process, worker_pid, :normal})

    refute_receive {:tracker_update, ^issue_id, _}, 200

    snapshot = GenServer.call(pid, :snapshot)
    assert [%{issue_id: ^issue_id, reason: "push_failed"}] = snapshot.blocked
  end

  defp put_running_entry(pid, issue_id, ref, worker_pid, attrs) do
    issue = %Issue{
      id: issue_id,
      identifier: "PRI-170",
      title: "Move PR flow into Symphony",
      description: "Test issue",
      state: "In Progress",
      url: "https://linear.example/PRI-170"
    }

    started_at = DateTime.utc_now()

    running_entry =
      %{
        pid: worker_pid,
        ref: ref,
        identifier: issue.identifier,
        issue: issue,
        session_id: "session-1",
        acpx_record_id: "record-1",
        phase: "agent_completed",
        phase_started_at: started_at,
        last_transition_at: started_at,
        phase_history: [%{phase: "agent_completed", transitioned_at: started_at, reason: nil}],
        turn_count: 1,
        last_agent_message: nil,
        last_agent_timestamp: nil,
        last_agent_event: nil,
        last_raw_event_at: nil,
        started_at: started_at,
        progress_source: "none",
        last_workspace_activity_at: nil,
        last_process_seen_at: nil,
        agent_input_tokens: 0,
        agent_output_tokens: 0,
        agent_total_tokens: 0,
        agent_cached_read_tokens: 0,
        agent_cached_write_tokens: 0
      }
      |> Map.merge(attrs)

    initial_state = :sys.get_state(pid)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)
  end
end

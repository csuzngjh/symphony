defmodule SymphonyElixirWeb.PresenterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixirWeb.Presenter

  describe "state_payload/2 with blocked issues" do
    test "includes blocked array in response" do
      orchestrator_name = Module.concat(__MODULE__, :BlockedStateOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      blocked_at = DateTime.utc_now()

      blocked_entry = %{
        identifier: "MT-404",
        workspace_path: "/tmp/ws/MT-404",
        reason: "dirty workspace",
        dirty_files: ["lib/foo.ex"],
        last_error: "exit code 1",
        blocked_at: blocked_at
      }

      initial_state = :sys.get_state(pid)

      new_state =
        initial_state
        |> Map.put(:blocked, %{"issue-blocked-404" => blocked_entry})

      :sys.replace_state(pid, fn _ -> new_state end)

      payload = Presenter.state_payload(orchestrator_name, 5_000)

      assert is_list(payload.blocked)
      assert length(payload.blocked) == 1

      [entry] = payload.blocked
      assert entry.issue_id == "issue-blocked-404"
      assert entry.issue_identifier == "MT-404"
      assert entry.workspace_path == "/tmp/ws/MT-404"
      assert entry.reason == "dirty workspace"
      assert entry.dirty_files == ["lib/foo.ex"]
      assert entry.last_error == "exit code 1"
      assert entry.blocked_at == DateTime.truncate(blocked_at, :second) |> DateTime.to_iso8601()
    end

    test "includes counts.blocked in response" do
      orchestrator_name = Module.concat(__MODULE__, :BlockedCountsOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      blocked_at = DateTime.utc_now()

      initial_state = :sys.get_state(pid)

      new_state =
        initial_state
        |> Map.put(:blocked, %{
          "issue-b1" => %{
            identifier: "MT-100",
            workspace_path: "/tmp/ws/MT-100",
            reason: "dirty",
            dirty_files: [],
            last_error: nil,
            blocked_at: blocked_at
          },
          "issue-b2" => %{
            identifier: "MT-200",
            workspace_path: "/tmp/ws/MT-200",
            reason: "stall",
            dirty_files: ["a.ex"],
            last_error: "timeout",
            blocked_at: blocked_at
          }
        })

      :sys.replace_state(pid, fn _ -> new_state end)

      payload = Presenter.state_payload(orchestrator_name, 5_000)

      assert payload.counts.blocked == 2
    end

    test "returns empty blocked array when no blocked issues" do
      orchestrator_name = Module.concat(__MODULE__, :NoBlockedOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      payload = Presenter.state_payload(orchestrator_name, 5_000)

      assert payload.blocked == []
      assert payload.counts.blocked == 0
    end
  end

  describe "issue_payload/3 with blocked issues" do
    test "returns blocked issue when found in snapshot" do
      orchestrator_name = Module.concat(__MODULE__, :BlockedIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      blocked_at = DateTime.utc_now()

      blocked_entry = %{
        identifier: "MT-999",
        workspace_path: "/tmp/ws/MT-999",
        reason: "dirty workspace",
        dirty_files: ["lib/bar.ex", "test/bar_test.exs"],
        last_error: "exit code 1",
        blocked_at: blocked_at
      }

      initial_state = :sys.get_state(pid)

      new_state =
        initial_state
        |> Map.put(:blocked, %{"issue-blocked-999" => blocked_entry})

      :sys.replace_state(pid, fn _ -> new_state end)

      assert {:ok, payload} = Presenter.issue_payload("MT-999", orchestrator_name, 5_000)

      assert payload.issue_identifier == "MT-999"
      assert payload.issue_id == "issue-blocked-999"
      assert payload.status == "blocked"
      assert payload.blocked.reason == "dirty workspace"
      assert payload.blocked.workspace_path == "/tmp/ws/MT-999"
      assert payload.blocked.dirty_files == ["lib/bar.ex", "test/bar_test.exs"]
      assert payload.blocked.last_error == "exit code 1"
      assert payload.blocked.blocked_at == DateTime.truncate(blocked_at, :second) |> DateTime.to_iso8601()
    end

    test "returns issue_not_found when identifier not in running, retrying, or blocked" do
      orchestrator_name = Module.concat(__MODULE__, :NotFoundOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      assert {:error, :issue_not_found} = Presenter.issue_payload("MT-NONEXISTENT", orchestrator_name, 5_000)
    end

    test "prefers running status over blocked when both present" do
      orchestrator_name = Module.concat(__MODULE__, :RunningAndBlockedOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      issue_id = "issue-both"
      identifier = "MT-BOTH"
      blocked_at = DateTime.utc_now()
      started_at = DateTime.utc_now()

      issue = %SymphonyElixir.Linear.Issue{
        id: issue_id,
        identifier: identifier,
        title: "Both test",
        description: "Running and blocked",
        state: "In Progress",
        url: "https://example.org/issues/MT-BOTH"
      }

      running_entry = %{
        pid: self(),
        ref: make_ref(),
        identifier: identifier,
        issue: issue,
        session_id: "sess-both",
        agent_session_pid: nil,
        turn_count: 1,
        last_agent_message: nil,
        last_agent_timestamp: started_at,
        last_agent_event: "turn_complete",
        started_at: started_at,
        agent_input_tokens: 10,
        agent_output_tokens: 20,
        agent_total_tokens: 30
      }

      blocked_entry = %{
        identifier: identifier,
        workspace_path: "/tmp/ws/MT-BOTH",
        reason: "dirty",
        dirty_files: [],
        last_error: nil,
        blocked_at: blocked_at
      }

      initial_state = :sys.get_state(pid)

      new_state =
        initial_state
        |> Map.put(:running, Map.put(initial_state.running, issue_id, running_entry))
        |> Map.put(:blocked, Map.put(initial_state.blocked, issue_id, blocked_entry))

      :sys.replace_state(pid, fn _ -> new_state end)

      assert {:ok, payload} = Presenter.issue_payload(identifier, orchestrator_name, 5_000)
      assert payload.status == "running"
      assert payload.running != nil
      assert payload.blocked != nil
    end
  end

  describe "state_payload/2 running entry progress fields" do
    test "includes progress_source, last_progress_at, last_workspace_activity_at, process_alive" do
      orchestrator_name = Module.concat(__MODULE__, :ProgressFieldsOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      issue_id = "issue-progress"
      identifier = "MT-PROG"
      started_at = DateTime.utc_now()
      workspace_activity_at = DateTime.utc_now() |> DateTime.add(-60, :second)
      process_seen_at = DateTime.utc_now() |> DateTime.add(-30, :second)

      issue = %SymphonyElixir.Linear.Issue{
        id: issue_id,
        identifier: identifier,
        title: "Progress test",
        description: "Testing progress fields",
        state: "In Progress",
        url: "https://example.org/issues/MT-PROG"
      }

      running_entry = %{
        pid: self(),
        ref: make_ref(),
        identifier: identifier,
        issue: issue,
        session_id: "sess-progress",
        agent_session_pid: nil,
        turn_count: 1,
        last_agent_message: nil,
        last_agent_timestamp: started_at,
        last_agent_event: "turn_complete",
        started_at: started_at,
        agent_input_tokens: 10,
        agent_output_tokens: 20,
        agent_total_tokens: 30,
        progress_source: "workspace_activity",
        last_workspace_activity_at: workspace_activity_at,
        last_process_seen_at: process_seen_at
      }

      initial_state = :sys.get_state(pid)

      new_state =
        initial_state
        |> Map.put(:running, Map.put(initial_state.running, issue_id, running_entry))

      :sys.replace_state(pid, fn _ -> new_state end)

      payload = Presenter.state_payload(orchestrator_name, 5_000)

      assert length(payload.running) == 1

      [entry] = payload.running
      assert entry.progress_source == "workspace_activity"
      assert entry.last_workspace_activity_at == DateTime.truncate(workspace_activity_at, :second) |> DateTime.to_iso8601()
      assert entry.process_alive == true
      assert entry.last_progress_at != nil
    end

    test "last_progress_at returns most recent timestamp among progress signals" do
      orchestrator_name = Module.concat(__MODULE__, :LatestProgressOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      issue_id = "issue-latest"
      identifier = "MT-LATEST"
      started_at = DateTime.utc_now()
      raw_event_at = DateTime.utc_now() |> DateTime.add(-120, :second)
      workspace_activity_at = DateTime.utc_now() |> DateTime.add(-60, :second)
      process_seen_at = DateTime.utc_now() |> DateTime.add(-10, :second)

      issue = %SymphonyElixir.Linear.Issue{
        id: issue_id,
        identifier: identifier,
        title: "Latest progress test",
        description: "Testing latest progress",
        state: "In Progress",
        url: "https://example.org/issues/MT-LATEST"
      }

      running_entry = %{
        pid: self(),
        ref: make_ref(),
        identifier: identifier,
        issue: issue,
        session_id: "sess-latest",
        agent_session_pid: nil,
        turn_count: 1,
        last_agent_message: nil,
        last_agent_timestamp: started_at,
        last_agent_event: "turn_complete",
        started_at: started_at,
        agent_input_tokens: 10,
        agent_output_tokens: 20,
        agent_total_tokens: 30,
        progress_source: "raw_event",
        last_raw_event_at: raw_event_at,
        last_workspace_activity_at: workspace_activity_at,
        last_process_seen_at: process_seen_at
      }

      initial_state = :sys.get_state(pid)

      new_state =
        initial_state
        |> Map.put(:running, Map.put(initial_state.running, issue_id, running_entry))

      :sys.replace_state(pid, fn _ -> new_state end)

      payload = Presenter.state_payload(orchestrator_name, 5_000)

      [entry] = payload.running
      assert entry.last_progress_at == DateTime.truncate(process_seen_at, :second) |> DateTime.to_iso8601()
    end

    test "process_alive is false for dead pids" do
      orchestrator_name = Module.concat(__MODULE__, :DeadPidOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      issue_id = "issue-dead-pid"
      identifier = "MT-DEAD"
      started_at = DateTime.utc_now()
      dead_pid = spawn(fn -> :ok end)
      Process.sleep(10)

      issue = %SymphonyElixir.Linear.Issue{
        id: issue_id,
        identifier: identifier,
        title: "Dead pid test",
        description: "Testing dead pid",
        state: "In Progress",
        url: "https://example.org/issues/MT-DEAD"
      }

      running_entry = %{
        pid: dead_pid,
        ref: make_ref(),
        identifier: identifier,
        issue: issue,
        session_id: "sess-dead",
        agent_session_pid: nil,
        turn_count: 0,
        last_agent_message: nil,
        last_agent_timestamp: nil,
        last_agent_event: nil,
        started_at: started_at,
        agent_input_tokens: 0,
        agent_output_tokens: 0,
        agent_total_tokens: 0,
        progress_source: "none"
      }

      initial_state = :sys.get_state(pid)

      new_state =
        initial_state
        |> Map.put(:running, Map.put(initial_state.running, issue_id, running_entry))

      :sys.replace_state(pid, fn _ -> new_state end)

      payload = Presenter.state_payload(orchestrator_name, 5_000)

      [entry] = payload.running
      assert entry.process_alive == false
    end

    test "progress fields default when missing from running entry" do
      orchestrator_name = Module.concat(__MODULE__, :DefaultProgressOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      issue_id = "issue-defaults"
      identifier = "MT-DEFAULTS"
      started_at = DateTime.utc_now()

      issue = %SymphonyElixir.Linear.Issue{
        id: issue_id,
        identifier: identifier,
        title: "Defaults test",
        description: "Testing defaults",
        state: "In Progress",
        url: "https://example.org/issues/MT-DEFAULTS"
      }

      running_entry = %{
        pid: self(),
        ref: make_ref(),
        identifier: identifier,
        issue: issue,
        session_id: "sess-defaults",
        agent_session_pid: nil,
        turn_count: 0,
        last_agent_message: nil,
        last_agent_timestamp: started_at,
        last_agent_event: nil,
        started_at: started_at,
        agent_input_tokens: 0,
        agent_output_tokens: 0,
        agent_total_tokens: 0
      }

      initial_state = :sys.get_state(pid)

      new_state =
        initial_state
        |> Map.put(:running, Map.put(initial_state.running, issue_id, running_entry))

      :sys.replace_state(pid, fn _ -> new_state end)

      payload = Presenter.state_payload(orchestrator_name, 5_000)

      [entry] = payload.running
      assert entry.progress_source == "none"
      assert entry.last_progress_at == nil
      assert entry.last_workspace_activity_at == nil
      assert entry.process_alive == true
    end
  end

  describe "issue_payload/3 running entry progress fields" do
    test "includes progress_source, last_progress_at, last_workspace_activity_at, process_alive" do
      orchestrator_name = Module.concat(__MODULE__, :IssueProgressOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      issue_id = "issue-iprog"
      identifier = "MT-IPROG"
      started_at = DateTime.utc_now()
      workspace_activity_at = DateTime.utc_now() |> DateTime.add(-30, :second)

      issue = %SymphonyElixir.Linear.Issue{
        id: issue_id,
        identifier: identifier,
        title: "Issue progress test",
        description: "Testing issue progress fields",
        state: "In Progress",
        url: "https://example.org/issues/MT-IPROG"
      }

      running_entry = %{
        pid: self(),
        ref: make_ref(),
        identifier: identifier,
        issue: issue,
        session_id: "sess-iprog",
        agent_session_pid: nil,
        turn_count: 1,
        last_agent_message: nil,
        last_agent_timestamp: started_at,
        last_agent_event: "turn_complete",
        started_at: started_at,
        agent_input_tokens: 10,
        agent_output_tokens: 20,
        agent_total_tokens: 30,
        progress_source: "workspace_activity",
        last_workspace_activity_at: workspace_activity_at
      }

      initial_state = :sys.get_state(pid)

      new_state =
        initial_state
        |> Map.put(:running, Map.put(initial_state.running, issue_id, running_entry))

      :sys.replace_state(pid, fn _ -> new_state end)

      assert {:ok, payload} = Presenter.issue_payload(identifier, orchestrator_name, 5_000)

      assert payload.running.progress_source == "workspace_activity"
      assert payload.running.last_workspace_activity_at == DateTime.truncate(workspace_activity_at, :second) |> DateTime.to_iso8601()
      assert payload.running.process_alive == true
      assert payload.running.last_progress_at != nil
    end
  end

  describe "state_payload/2 branch_name in running entry" do
    test "includes branch_name when set" do
      orchestrator_name = Module.concat(__MODULE__, :BranchNameOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      issue_id = "issue-branch-name"
      identifier = "MT-BRANCH"
      started_at = DateTime.utc_now()

      issue = %SymphonyElixir.Linear.Issue{
        id: issue_id,
        identifier: identifier,
        title: "Branch name test",
        description: "Testing branch_name in payload",
        state: "In Progress",
        url: "https://example.org/issues/MT-BRANCH"
      }

      running_entry = %{
        pid: self(),
        ref: make_ref(),
        identifier: identifier,
        issue: issue,
        session_id: "sess-branch",
        agent_session_pid: nil,
        turn_count: 1,
        last_agent_message: nil,
        last_agent_timestamp: started_at,
        last_agent_event: "session_ready",
        started_at: started_at,
        agent_input_tokens: 0,
        agent_output_tokens: 0,
        agent_total_tokens: 0,
        progress_source: "none",
        last_workspace_activity_at: nil,
        last_process_seen_at: nil,
        branch_name: "symphony/mt-branch-branch-name-test"
      }

      initial_state = :sys.get_state(pid)

      new_state =
        initial_state
        |> Map.put(:running, Map.put(initial_state.running, issue_id, running_entry))

      :sys.replace_state(pid, fn _ -> new_state end)

      payload = Presenter.state_payload(orchestrator_name, 5_000)

      assert length(payload.running) == 1

      [entry] = payload.running
      assert entry.branch_name == "symphony/mt-branch-branch-name-test"
    end

    test "branch_name is nil when not set" do
      orchestrator_name = Module.concat(__MODULE__, :NoBranchNameOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      issue_id = "issue-no-branch"
      identifier = "MT-NOBRANCH"
      started_at = DateTime.utc_now()

      issue = %SymphonyElixir.Linear.Issue{
        id: issue_id,
        identifier: identifier,
        title: "No branch test",
        description: "Testing nil branch_name",
        state: "In Progress",
        url: "https://example.org/issues/MT-NOBRANCH"
      }

      running_entry = %{
        pid: self(),
        ref: make_ref(),
        identifier: identifier,
        issue: issue,
        session_id: nil,
        agent_session_pid: nil,
        turn_count: 0,
        last_agent_message: nil,
        last_agent_timestamp: nil,
        last_agent_event: nil,
        started_at: started_at,
        agent_input_tokens: 0,
        agent_output_tokens: 0,
        agent_total_tokens: 0,
        progress_source: "none",
        last_workspace_activity_at: nil,
        last_process_seen_at: nil
      }

      initial_state = :sys.get_state(pid)

      new_state =
        initial_state
        |> Map.put(:running, Map.put(initial_state.running, issue_id, running_entry))

      :sys.replace_state(pid, fn _ -> new_state end)

      payload = Presenter.state_payload(orchestrator_name, 5_000)

      assert length(payload.running) == 1

      [entry] = payload.running
      assert entry.branch_name == nil
    end
  end
end

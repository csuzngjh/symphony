defmodule SymphonyElixir.WorkspaceBoundaryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{PromptBuilder, Workspace}
  alias SymphonyElixir.AgentRunner.AcpxSession

  describe "Prompt boundary enforcement" do
    setup do
      workflow_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-boundary-workflow-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workflow_root)
      workflow_file = Path.join(workflow_root, "WORKFLOW.md")

      File.write!(workflow_file, """
      ---
      workspace:
        root: #{Path.join(System.tmp_dir!(), "symphony_workspaces")}
        source_checkout_path: D:/Code/principles
      ---

      ## Workspace Safety Contract

      {% if workspace_path %}
      - Worker workspace: {{ workspace_path }}
      - Only operate inside this worker workspace. All file edits, tool calls, and commands must target paths within this workspace.
      {% endif %}
      {% if source_checkout_path %}
      - Do NOT cd to {{ source_checkout_path }}. The source checkout is read-only reference, not your working directory.
      - Do NOT edit files in {{ source_checkout_path }}.
      {% endif %}

      You are working on a Linear ticket `{{ issue.identifier }}`
      """)

      Workflow.set_workflow_file_path(workflow_file)

      if Process.whereis(SymphonyElixir.WorkflowStore) do
        try do
          SymphonyElixir.WorkflowStore.force_reload()
        catch
          :exit, _reason -> :ok
        end
      end

      on_exit(fn ->
        File.rm_rf(workflow_root)
      end)

      :ok
    end

    test "prompt includes workspace path when provided" do
      issue = %Issue{
        id: "test-1",
        identifier: "PRI-151",
        title: "Test issue",
        state: "In Progress",
        url: "https://example.org/issues/PRI-151"
      }

      prompt = PromptBuilder.build_prompt(issue, workspace_path: "D:/code/principles-workspaces/PRI-151")

      assert prompt =~ "D:/code/principles-workspaces/PRI-151"
      assert prompt =~ "Only operate inside this worker workspace"
    end

    test "prompt includes source checkout path as forbidden when provided" do
      issue = %Issue{
        id: "test-2",
        identifier: "PRI-151",
        title: "Test issue",
        state: "In Progress",
        url: "https://example.org/issues/PRI-151"
      }

      prompt = PromptBuilder.build_prompt(issue,
        workspace_path: "D:/code/principles-workspaces/PRI-151",
        source_checkout_path: "D:/Code/principles"
      )

      assert prompt =~ "D:/Code/principles"
      assert prompt =~ "Do NOT cd to"
    end

    test "prompt does not describe source checkout as editable repo" do
      issue = %Issue{
        id: "test-3",
        identifier: "PRI-151",
        title: "Test issue",
        state: "In Progress",
        url: "https://example.org/issues/PRI-151"
      }

      prompt = PromptBuilder.build_prompt(issue,
        workspace_path: "D:/code/principles-workspaces/PRI-151",
        source_checkout_path: "D:/Code/principles"
      )

      assert prompt =~ "Do NOT edit files in D:/Code/principles"
      refute prompt =~ "working directory: D:/Code/principles"
      refute prompt =~ "you can edit D:/Code/principles"
    end
  end

  describe "ACPX launch cwd" do
    test "build_global_args uses explicit cwd instead of defaulting to dot" do
      build_global_args = AcpxSession.__testing__().build_global_args

      args = build_global_args.(%{}, "/tmp/my-workspace")

      cwd_idx = Enum.find_index(args, &(&1 == "--cwd"))
      assert cwd_idx != nil
      assert Enum.at(args, cwd_idx + 1) == "/tmp/my-workspace"
    end

    test "build_global_args falls back to dot when cwd is nil" do
      build_global_args = AcpxSession.__testing__().build_global_args

      args = build_global_args.(%{}, nil)

      cwd_idx = Enum.find_index(args, &(&1 == "--cwd"))
      assert Enum.at(args, cwd_idx + 1) == "."
    end

    test "build_prompt_args passes workspace cwd" do
      build_prompt_args = AcpxSession.__testing__().build_prompt_args

      args = build_prompt_args.("claude", "my-session", "/tmp/prompt.txt", %{}, "/workspace/PRI-151")

      cwd_idx = Enum.find_index(args, &(&1 == "--cwd"))
      assert Enum.at(args, cwd_idx + 1) == "/workspace/PRI-151"
    end
  end

  describe "Worker preflight validation" do
    test "returns error when workspace does not exist" do
      write_workflow_file!(Workflow.workflow_file_path())

      nonexistent = Path.join(System.tmp_dir!(), "symphony-nonexistent-#{System.unique_integer([:positive])}")

      assert {:error, {:workspace_not_found, ^nonexistent}} = Workspace.validate_worker_workspace(nonexistent)
    end

    test "returns error when workspace is not a git repo" do
      write_workflow_file!(Workflow.workflow_file_path())

      tmp_dir = Path.join(System.tmp_dir!(), "symphony-not-git-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf(tmp_dir) end)

      assert {:error, {:workspace_not_git_repo, ^tmp_dir}} = Workspace.validate_worker_workspace(tmp_dir)
    end

    test "returns ok for valid workspace git repo" do
      tmp_dir = Path.join(System.tmp_dir!(), "symphony-valid-ws-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf(tmp_dir) end)

      {_, 0} = System.cmd("git", ["init"], cd: tmp_dir, stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["config", "user.email", "test@test.com"], cd: tmp_dir)
      {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: tmp_dir)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: tmp_dir
      )

      assert :ok = Workspace.validate_worker_workspace(tmp_dir)
    end

    test "returns error when workspace git root matches source checkout path" do
      tmp_dir = Path.join(System.tmp_dir!(), "symphony-source-checkout-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf(tmp_dir) end)

      {_, 0} = System.cmd("git", ["init"], cd: tmp_dir, stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["config", "user.email", "test@test.com"], cd: tmp_dir)
      {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: tmp_dir)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.dirname(tmp_dir),
        workspace_source_checkout_path: tmp_dir
      )

      assert {:error, {:workspace_is_source_checkout, ^tmp_dir}} = Workspace.validate_worker_workspace(tmp_dir)
    end
  end

  describe "Boundary violation detection" do
    test "detects cd to source checkout path" do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_source_checkout_path: "D:/Code/principles"
      )

      text = "I will cd D:/Code/principles to check the source code"

      assert {:violation, "D:/Code/principles"} =
               detect_boundary_violation_for_test(text)
    end

    test "detects Set-Location to source checkout path" do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_source_checkout_path: "D:/Code/principles"
      )

      text = "Set-Location D:/Code/principles"

      assert {:violation, "D:/Code/principles"} =
               detect_boundary_violation_for_test(text)
    end

    test "does not flag normal workspace operations" do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_source_checkout_path: "D:/Code/principles"
      )

      text = "I will work in D:/code/principles-workspaces/PRI-151 and edit files there"

      assert :ok = detect_boundary_violation_for_test(text)
    end

    test "returns ok when no source_checkout_path configured" do
      write_workflow_file!(Workflow.workflow_file_path())

      text = "cd D:/Code/principles"

      assert :ok = detect_boundary_violation_for_test(text)
    end
  end

  describe "Orchestrator boundary violation blocking" do
    test "blocks issue when agent attempts cd to source checkout" do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_source_checkout_path: "D:/Code/principles"
      )

      issue_id = "issue-bv-test"

      issue = %Issue{
        id: issue_id,
        identifier: "PRI-BV",
        title: "Boundary violation test",
        state: "In Progress",
        url: "https://example.org/issues/PRI-BV"
      }

      orchestrator_name = Module.concat(__MODULE__, :BoundaryViolationOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      running_entry = %{
        pid: nil,
        ref: nil,
        identifier: "PRI-BV",
        issue: issue,
        worker_host: nil,
        workspace_path: "D:/code/principles-workspaces/PRI-BV",
        status: :running,
        session_name: nil,
        session_id: nil,
        attempt_id: issue_id,
        phase: "running",
        last_agent_message: nil,
        last_agent_timestamp: nil,
        last_agent_event: nil,
        last_raw_event_at: DateTime.utc_now(),
        last_raw_preview: nil,
        agent_session_pid: nil,
        agent_input_tokens: 0,
        agent_output_tokens: 0,
        agent_total_tokens: 0,
        agent_cached_read_tokens: 0,
        agent_cached_write_tokens: 0,
        agent_last_reported_input_tokens: 0,
        agent_last_reported_output_tokens: 0,
        agent_last_reported_total_tokens: 0,
        agent_last_reported_cached_read_tokens: 0,
        agent_last_reported_cached_write_tokens: 0,
        turn_count: 1,
        retry_attempt: 0,
        started_at: DateTime.utc_now(),
        last_workspace_activity_at: nil,
        last_workspace_activity_scan_at: nil,
        last_process_seen_at: DateTime.utc_now(),
        progress_source: "raw_event"
      }

      state = :sys.get_state(pid)
      :sys.replace_state(pid, fn _ -> %{state | running: %{issue_id => running_entry}} end)

      send(pid, {:agent_worker_update, issue_id, %{
        event: :agent_message,
        timestamp: DateTime.utc_now(),
        payload: %{"content" => "I will cd D:/Code/principles to check the source"}
      }})

      Process.sleep(100)

      state_after = :sys.get_state(pid)
      refute Map.has_key?(state_after.running, issue_id)
      assert Map.has_key?(state_after.blocked, issue_id)
      assert state_after.blocked[issue_id].reason == "workspace_boundary_violation"
    end

    test "does not block issue for normal workspace messages" do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_source_checkout_path: "D:/Code/principles"
      )

      issue_id = "issue-bv-safe"

      issue = %Issue{
        id: issue_id,
        identifier: "PRI-SAFE",
        title: "Safe message test",
        state: "In Progress",
        url: "https://example.org/issues/PRI-SAFE"
      }

      orchestrator_name = Module.concat(__MODULE__, :SafeMessageOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      running_entry = %{
        pid: nil,
        ref: nil,
        identifier: "PRI-SAFE",
        issue: issue,
        worker_host: nil,
        workspace_path: "D:/code/principles-workspaces/PRI-SAFE",
        status: :running,
        session_name: nil,
        session_id: nil,
        attempt_id: issue_id,
        phase: "running",
        last_agent_message: nil,
        last_agent_timestamp: nil,
        last_agent_event: nil,
        last_raw_event_at: nil,
        last_raw_preview: nil,
        agent_session_pid: nil,
        agent_input_tokens: 0,
        agent_output_tokens: 0,
        agent_total_tokens: 0,
        agent_cached_read_tokens: 0,
        agent_cached_write_tokens: 0,
        agent_last_reported_input_tokens: 0,
        agent_last_reported_output_tokens: 0,
        agent_last_reported_total_tokens: 0,
        agent_last_reported_cached_read_tokens: 0,
        agent_last_reported_cached_write_tokens: 0,
        turn_count: 1,
        retry_attempt: 0,
        started_at: DateTime.utc_now(),
        last_workspace_activity_at: nil,
        last_workspace_activity_scan_at: nil,
        last_process_seen_at: nil,
        progress_source: "none"
      }

      state = :sys.get_state(pid)
      :sys.replace_state(pid, fn _ -> %{state | running: %{issue_id => running_entry}} end)

      send(pid, {:agent_worker_update, issue_id, %{
        event: :agent_message,
        timestamp: DateTime.utc_now(),
        payload: %{"content" => "Working in the workspace, editing files"}
      }})

      Process.sleep(100)

      state_after = :sys.get_state(pid)
      assert Map.has_key?(state_after.running, issue_id)
      refute Map.has_key?(state_after.blocked, issue_id)
    end
  end

  defp detect_boundary_violation_for_test(text) do
    config = Config.settings!()
    source_checkout_path = config.workspace.source_checkout_path

    if source_checkout_path != nil and source_checkout_path != "" do
      cd_patterns = [
        ~r/cd\s+#{Regex.escape(source_checkout_path)}/i,
        ~r/Set-Location\s+#{Regex.escape(source_checkout_path)}/i,
        ~r/Push-Location\s+#{Regex.escape(source_checkout_path)}/i,
        ~r/cd\s+["']#{Regex.escape(source_checkout_path)}["']/i
      ]

      text_lower = String.downcase(text)
      forbidden_lower = String.downcase(source_checkout_path)

      cond do
        Enum.any?(cd_patterns, &Regex.match?(&1, text)) ->
          {:violation, source_checkout_path}

        String.contains?(text_lower, forbidden_lower) and
          String.contains?(text_lower, "cd ") ->
          {:violation, source_checkout_path}

        true ->
          :ok
      end
    else
      :ok
    end
  end
end

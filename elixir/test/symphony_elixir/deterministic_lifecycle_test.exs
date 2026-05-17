defmodule SymphonyElixir.DeterministicLifecycleTest do
  use SymphonyElixir.TestSupport

  @moduletag :integration
  @moduletag timeout: 10_000

  test "fake ACPX drives a local issue from workspace creation through agent completion" do
    run_id = "symphony-fake-lifecycle-#{System.unique_integer([:positive])}"
    workspace_root = Path.join(System.tmp_dir!(), run_id)
    issue = %Issue{
      id: "issue-fake-lifecycle",
      identifier: "FAKE-1",
      title: "Deterministic lifecycle",
      description: "Exercise fake ACPX without network",
      state: "Todo",
      url: "https://example.org/issues/FAKE-1",
      labels: ["ready-for-agent"],
      blocked_by: []
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done"],
      max_turns: 1,
      agent_turn_timeout_ms: 10_000,
      prompt: "Use the fake ACPX harness for {{ issue.identifier }}."
    )

    workspace = Path.join(workspace_root, issue.identifier)
    init_clean_git_workspace!(workspace)

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)

    assert :ok =
             AgentRunner.run(issue, self(),
               max_turns: 1,
               issue_state_fetcher: fn [issue_id] ->
                 assert issue_id == issue.id
                 {:ok, [%{issue | state: "Done"}]}
               end
             )

    messages = drain_messages([])

    expected_workspace = normalize_path_for_platform(workspace)

    assert Enum.any?(messages, fn
             {:worker_runtime_info, "issue-fake-lifecycle", %{workspace_path: actual_workspace}} ->
               normalize_path_for_platform(actual_workspace) == expected_workspace

             _ ->
               false
           end)
    assert Enum.any?(messages, &match?({:agent_worker_update, "issue-fake-lifecycle", %{event: :branch_prepared, branch_name: "symphony/fake-1-deterministic-lifecycle"}}, &1))

    assert Enum.any?(messages, fn
             {:agent_worker_update, "issue-fake-lifecycle", %{event: :session_ready, session_id: "fake-session-001", acpx_record_id: "fake-record-001"}} -> true
             _ -> false
           end)

    assert Enum.any?(messages, fn
             {:agent_worker_update, "issue-fake-lifecycle", %{event: :agent_message, payload: %{"content" => message}}} ->
               message =~ "Task completed by fake ACPX." or message =~ "Hello from fake ACPX."

             _ ->
               false
           end)

    assert Enum.any?(messages, &match?({:agent_worker_update, "issue-fake-lifecycle", %{event: :turn_completed}}, &1))
  end

  defp init_clean_git_workspace!(workspace) do
    File.mkdir_p!(workspace)
    run_git!(["init"], workspace)
    run_git!(["config", "user.email", "symphony-test@example.invalid"], workspace)
    run_git!(["config", "user.name", "Symphony Test"], workspace)
    File.write!(Path.join(workspace, "README.md"), "# fake lifecycle\n")
    run_git!(["add", "README.md"], workspace)
    run_git!(["commit", "-m", "init"], workspace)
  end

  defp run_git!(args, cwd) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end

  defp drain_messages(acc) do
    receive do
      message -> drain_messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end

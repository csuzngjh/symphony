defmodule SymphonyElixir.OrchestratorAutoReviewTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Review.Result

  defmodule FakeReviewRunner do
    @moduledoc false

    def run(_issue, _workspace_path, _config, _opts \\ []) do
      {:ok,
       [
         Result.success(:code_quality, 85, "Good code", "Well structured", "Code looks clean"),
         Result.success(:security_audit, 90, "No issues", "Secure", "Safe"),
         Result.success(:test_coverage, 70, "Adequate", "Could improve", "Tests exist"),
         Result.success(:business_compliance, 80, "Compliant", "Meets requirements", "OK")
       ]}
    end
  end

  defmodule FailingReviewRunner do
    @moduledoc false

    def run(_issue, _workspace_path, _config, _opts \\ []) do
      {:error, :acpx_connection_refused}
    end
  end

  describe "Auto Review when review.enabled=false" do
    test "blocks issue in Auto Review state instead of silently ignoring" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_api_token: nil,
        tracker_kind: "memory",
        review_enabled: false
      )

      issue_id = "issue-ar-disabled"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-AR-DISABLED",
        title: "Auto Review disabled test",
        state: "Auto Review",
        url: "https://example.org/issues/MT-AR-DISABLED"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      orchestrator_name = Module.concat(__MODULE__, :ReviewDisabledOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      end)

      state = :sys.get_state(pid)
      refute Map.has_key?(state.blocked, issue_id)

      reconciled =
        Orchestrator.reconcile_issue_states_for_test([issue], state)

      assert Map.has_key?(reconciled.blocked, issue_id)
      assert reconciled.blocked[issue_id].reason == "auto_review_disabled"
      assert reconciled.blocked[issue_id].identifier == "MT-AR-DISABLED"
    end

    test "does not dispatch coding agent for Auto Review issue" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_api_token: nil,
        review_enabled: false
      )

      issue = %Issue{
        id: "issue-ar-no-dispatch",
        identifier: "MT-AR-NO-DISPATCH",
        title: "No dispatch test",
        state: "Auto Review",
        url: "https://example.org/issues/MT-AR-NO-DISPATCH"
      }

      orchestrator_name = Module.concat(__MODULE__, :NoDispatchOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      state = :sys.get_state(pid)

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    end
  end

  describe "Auto Review when review.enabled=true" do
    test "starts review once for Auto Review issue" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-ar-start-#{System.unique_integer([:positive])}"
        )

      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_api_token: nil,
        tracker_kind: "memory",
        workspace_root: workspace_root,
        review_enabled: true
      )

      issue_id = "issue-ar-start"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-AR-START",
        title: "Auto Review start test",
        state: "Auto Review",
        url: "https://example.org/issues/MT-AR-START"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      orchestrator_name = Module.concat(__MODULE__, :ReviewStartOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        Application.delete_env(:symphony_elixir, :memory_tracker_issues)
        File.rm_rf(test_root)
      end)

      state = :sys.get_state(pid)
      assert map_size(state.reviews) == 0

      reconciled =
        Orchestrator.reconcile_issue_states_for_test([issue], state)

      assert Map.has_key?(reconciled.reviews, issue_id)
      assert reconciled.reviews[issue_id].started_at != nil
    end

    test "does not start duplicate review while one is running" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-ar-dedupe-#{System.unique_integer([:positive])}"
        )

      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_api_token: nil,
        tracker_kind: "memory",
        workspace_root: workspace_root,
        review_enabled: true
      )

      issue_id = "issue-ar-dedupe"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-AR-DEDUPE",
        title: "Auto Review dedupe test",
        state: "Auto Review",
        url: "https://example.org/issues/MT-AR-DEDUPE"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      orchestrator_name = Module.concat(__MODULE__, :ReviewDedupeOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        Application.delete_env(:symphony_elixir, :memory_tracker_issues)
        File.rm_rf(test_root)
      end)

      state = :sys.get_state(pid)

      first =
        Orchestrator.reconcile_issue_states_for_test([issue], state)

      assert Map.has_key?(first.reviews, issue_id)

      second =
        Orchestrator.reconcile_issue_states_for_test([issue], first)

      assert Map.has_key?(second.reviews, issue_id)
      assert map_size(second.reviews) == 1
    end
  end

  describe "review_completed handler" do
    test "on success: removes from reviews map, creates comment, transitions to Human Review" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_api_token: nil,
        tracker_kind: "memory",
        review_enabled: true
      )

      issue_id = "issue-ar-complete"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-AR-COMPLETE",
        title: "Auto Review complete test",
        state: "Auto Review",
        url: "https://example.org/issues/MT-AR-COMPLETE"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name = Module.concat(__MODULE__, :ReviewCompleteOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        Application.delete_env(:symphony_elixir, :memory_tracker_issues)
        Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      end)

      state = :sys.get_state(pid)

      review_started_at = DateTime.utc_now()

      state_with_review = %{state | reviews: %{issue_id => %{started_at: review_started_at}}}
      :sys.replace_state(pid, fn _ -> state_with_review end)

      results = [
        Result.success(:code_quality, 85, "Good", "Details", "Clean"),
        Result.success(:security_audit, 90, "Safe", "Details", "Secure"),
        Result.success(:test_coverage, 70, "OK", "Details", "Covered"),
        Result.success(:business_compliance, 80, "Pass", "Details", "Compliant")
      ]

      send(pid, {:review_completed, issue, {:ok, results}})
      Process.sleep(100)

      state_after = :sys.get_state(pid)
      refute Map.has_key?(state_after.reviews, issue_id)

      assert_received {:memory_tracker_comment, ^issue_id, comment}
      assert comment =~ "自动评审报告"

      assert_received {:memory_tracker_state_update, ^issue_id, "Human Review"}
    end

    test "on error: removes from reviews map, creates failure comment, transitions to Human Review" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_api_token: nil,
        tracker_kind: "memory",
        review_enabled: true
      )

      issue_id = "issue-ar-error"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-AR-ERROR",
        title: "Auto Review error test",
        state: "Auto Review",
        url: "https://example.org/issues/MT-AR-ERROR"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name = Module.concat(__MODULE__, :ReviewErrorOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        Application.delete_env(:symphony_elixir, :memory_tracker_issues)
        Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      end)

      state = :sys.get_state(pid)

      review_started_at = DateTime.utc_now()

      state_with_review = %{state | reviews: %{issue_id => %{started_at: review_started_at}}}
      :sys.replace_state(pid, fn _ -> state_with_review end)

      send(pid, {:review_completed, issue, {:error, :acpx_connection_refused}})
      Process.sleep(100)

      state_after = :sys.get_state(pid)
      refute Map.has_key?(state_after.reviews, issue_id)

      assert_received {:memory_tracker_comment, ^issue_id, comment}
      assert comment =~ "自动评审失败"

      assert_received {:memory_tracker_state_update, ^issue_id, "Human Review"}
    end

    test "reviews map does not leak when review runner crashes" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_api_token: nil,
        tracker_kind: "memory",
        review_enabled: true
      )

      issue_id = "issue-ar-crash"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-AR-CRASH",
        title: "Auto Review crash test",
        state: "Auto Review",
        url: "https://example.org/issues/MT-AR-CRASH"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name = Module.concat(__MODULE__, :ReviewCrashOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        Application.delete_env(:symphony_elixir, :memory_tracker_issues)
        Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      end)

      state = :sys.get_state(pid)

      review_started_at = DateTime.utc_now()

      state_with_review = %{state | reviews: %{issue_id => %{started_at: review_started_at}}}
      :sys.replace_state(pid, fn _ -> state_with_review end)

      send(pid, {:review_completed, issue, {:error, :runner_crashed}})
      Process.sleep(100)

      state_after = :sys.get_state(pid)
      refute Map.has_key?(state_after.reviews, issue_id)
    end
  end

  describe "Auto Review blocked issue in snapshot" do
    test "blocked Auto Review issue appears in snapshot with auto_review_disabled reason" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_api_token: nil,
        review_enabled: false
      )

      issue_id = "issue-ar-snapshot"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-AR-SNAPSHOT",
        title: "Auto Review snapshot test",
        state: "Auto Review",
        url: "https://example.org/issues/MT-AR-SNAPSHOT"
      }

      orchestrator_name = Module.concat(__MODULE__, :ReviewSnapshotOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      state = :sys.get_state(pid)

      reconciled =
        Orchestrator.reconcile_issue_states_for_test([issue], state)

      :sys.replace_state(pid, fn _ -> reconciled end)

      snapshot = GenServer.call(pid, :snapshot)
      assert is_list(snapshot.blocked)

      blocked_entry = Enum.find(snapshot.blocked, &(&1.issue_id == issue_id))
      assert blocked_entry != nil
      assert blocked_entry.reason == "auto_review_disabled"
      assert blocked_entry.identifier == "MT-AR-SNAPSHOT"
    end
  end

  describe "should_dispatch_issue? excludes Auto Review" do
    test "Auto Review issue is not dispatched even with available slots" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_api_token: nil,
        review_enabled: true
      )

      issue = %Issue{
        id: "issue-ar-no-dispatch-enabled",
        identifier: "MT-AR-NO-DISPATCH-EN",
        title: "No dispatch when enabled",
        state: "Auto Review",
        url: "https://example.org/issues/MT-AR-NO-DISPATCH-EN"
      }

      orchestrator_name = Module.concat(__MODULE__, :NoDispatchEnabledOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      state = :sys.get_state(pid)

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    end

    test "In Progress issue is dispatched with available slots" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_api_token: nil
      )

      issue = %Issue{
        id: "issue-ip-dispatch",
        identifier: "MT-IP-DISPATCH",
        title: "In Progress dispatch test",
        state: "In Progress",
        url: "https://example.org/issues/MT-IP-DISPATCH"
      }

      orchestrator_name = Module.concat(__MODULE__, :InProgressDispatchOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      state = :sys.get_state(pid)

      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    end
  end
end

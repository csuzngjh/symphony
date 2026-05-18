defmodule SymphonyElixir.OrchestratorRoutingGateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator

  describe "project_slug routing gate" do
    test "project slug matching dispatches normally" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: "symphony",
        tracker_api_token: nil
      )

      issue = %Issue{
        id: "issue-slug-match",
        identifier: "MT-SLUG-MATCH",
        title: "Slug match",
        state: "In Progress",
        url: "https://example.org/issues/MT-SLUG-MATCH",
        project_slug: "symphony"
      }

      state = %Orchestrator.State{running: %{}, claimed: MapSet.new()}
      assert Orchestrator.should_dispatch_issue_for_test(issue, state) == true
    end

    test "project slug mismatch refuses dispatch" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: "symphony",
        tracker_api_token: nil
      )

      issue = %Issue{
        id: "issue-slug-mismatch",
        identifier: "MT-SLUG-MISMATCH",
        title: "Slug mismatch",
        state: "In Progress",
        url: "https://example.org/issues/MT-SLUG-MISMATCH",
        project_slug: "principles"
      }

      state = %Orchestrator.State{running: %{}, claimed: MapSet.new()}
      assert Orchestrator.should_dispatch_issue_for_test(issue, state) == false
    end

    test "issue without project_slug refuses when not allowed" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: "symphony",
        tracker_allow_unscoped_project_polling: false,
        tracker_api_token: nil
      )

      issue = %Issue{
        id: "issue-slug-nil-refused",
        identifier: "MT-SLUG-NIL",
        title: "Slug nil refused",
        state: "In Progress",
        url: "https://example.org/issues/MT-SLUG-NIL",
        project_slug: nil
      }

      state = %Orchestrator.State{running: %{}, claimed: MapSet.new()}
      assert Orchestrator.should_dispatch_issue_for_test(issue, state) == false
    end

    test "issue without project_slug dispatches when allowed" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: "symphony",
        tracker_allow_unscoped_project_polling: true,
        tracker_api_token: nil
      )

      issue = %Issue{
        id: "issue-slug-nil-allowed",
        identifier: "MT-SLUG-ALLOWED",
        title: "Slug nil allowed",
        state: "In Progress",
        url: "https://example.org/issues/MT-SLUG-ALLOWED",
        project_slug: nil
      }

      state = %Orchestrator.State{running: %{}, claimed: MapSet.new()}
      assert Orchestrator.should_dispatch_issue_for_test(issue, state) == true
    end

    test "workflow without project_slug dispatches all issues" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: nil,
        tracker_api_token: nil
      )

      issue = %Issue{
        id: "issue-no-config-slug",
        identifier: "MT-NO-CONFIG-SLUG",
        title: "No config slug",
        state: "In Progress",
        url: "https://example.org/issues/MT-NO-CONFIG-SLUG",
        project_slug: nil
      }

      state = %Orchestrator.State{running: %{}, claimed: MapSet.new()}
      assert Orchestrator.should_dispatch_issue_for_test(issue, state) == true
    end

    test "project slug matching is case-insensitive" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: "Symphony",
        tracker_api_token: nil
      )

      issue = %Issue{
        id: "issue-slug-case",
        identifier: "MT-SLUG-CASE",
        title: "Slug case insensitive",
        state: "In Progress",
        url: "https://example.org/issues/MT-SLUG-CASE",
        project_slug: "symphony"
      }

      state = %Orchestrator.State{running: %{}, claimed: MapSet.new()}
      assert Orchestrator.should_dispatch_issue_for_test(issue, state) == true
    end
  end
end

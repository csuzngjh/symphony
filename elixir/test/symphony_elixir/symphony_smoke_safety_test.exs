defmodule SymphonyElixir.SymphonySmokeSafetyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Linear.Issue

  test "workflow supports explicit issue identifier allowlist for controlled dispatch" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      tracker_issue_identifiers: [" PRI-123 ", "", "PRI-123", "PRI-124"],
      codex_command: "claude"
    )

    assert Config.settings!().tracker.issue_identifiers == ["PRI-123", "PRI-124"]
  end

  test "linear client issue identifier allowlist filters candidate issues" do
    issues = [
      %Issue{id: "issue-1", identifier: "PRI-122"},
      %Issue{id: "issue-2", identifier: "PRI-123"},
      %Issue{id: "issue-3", identifier: "PRI-124"}
    ]

    filtered = Client.filter_issue_identifiers_for_test(issues, ["PRI-123", "PRI-124"])

    assert Enum.map(filtered, & &1.identifier) == ["PRI-123", "PRI-124"]
  end

  test "linear client issue identifier allowlist is disabled when empty" do
    issues = [
      %Issue{id: "issue-1", identifier: "PRI-122"},
      %Issue{id: "issue-2", identifier: "PRI-123"}
    ]

    assert Client.filter_issue_identifiers_for_test(issues, []) == issues
  end

  test "linear client can fetch explicit issue identifiers without project filtering" do
    graphql_fun = fn query, variables ->
      send(self(), {:fetch_identifier, query, variables})

      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "id" => "issue-127",
             "identifier" => variables.id,
             "title" => "Smoke issue",
             "state" => %{"name" => "In Progress"},
             "labels" => %{"nodes" => []},
             "inverseRelations" => %{"nodes" => []}
           }
         }
       }}
    end

    assert {:ok, [issue]} = Client.fetch_issue_identifiers_for_test(["PRI-127"], graphql_fun)

    assert issue.identifier == "PRI-127"
    assert issue.state == "In Progress"
    assert_receive {:fetch_identifier, query, %{id: "PRI-127", relationFirst: 50}}
    assert query =~ "SymphonyLinearIssueByIdentifier"
  end
end

defmodule SymphonyElixir.ControlPlane.PrFlowTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ControlPlane.PrFlow

  defp issue do
    %Issue{
      id: "issue-pr-flow",
      identifier: "PRI-170",
      title: "Move pr flow into Symphony",
      description: "Test issue",
      state: "In Progress",
      url: "https://linear.example/PRI-170"
    }
  end

  defp setup_completion_report(workspace_path, files \\ ["lib/example.ex", "test/example_test.exs"]) do
    completion_dir = Path.join(workspace_path, ".symphony")
    File.mkdir_p!(completion_dir)

    completion_content = Jason.encode!(%{
      "status" => "ready_for_review",
      "changed_files" => files,
      "tests" => [%{"command" => "mix test", "result" => "pass"}]
    })

    File.write!(Path.join(completion_dir, "agent-completion.json"), completion_content)
  end

  test "commits, pushes, creates PR, and moves tracker state after agent completion" do
    parent = self()
    workspace_path = Path.join(System.tmp_dir!(), "symphony_pr_flow_test")
    File.rm_rf!(workspace_path)
    File.mkdir_p!(workspace_path)
    setup_completion_report(workspace_path)

    command_runner = fn cmd, args, opts ->
      send(parent, {:command, cmd, args, opts})

      case {cmd, args} do
        {"git", ["status", "--porcelain"]} -> {" M lib/example.ex\n?? test/example_test.exs\n", 0}
        {"git", ["add", "--", "lib/example.ex", "test/example_test.exs"]} -> {"", 0}
        {"git", ["commit", "-m", message]} -> assert message =~ "pri-170"; {"[branch abc] commit", 0}
        {"git", ["rev-parse", "HEAD"]} -> {"abc123\n", 0}
        {"git", ["push", "-u", "origin", "symphony/pri-170-owned-pr"]} -> {"pushed", 0}
        {"gh", ["pr", "create" | rest]} -> assert "--head" in rest; {"https://github.com/acme/repo/pull/123\n", 0}
      end
    end

    tracker_update = fn issue_id, state_name ->
      send(parent, {:tracker_update, issue_id, state_name})
      :ok
    end

    assert {:ok, result} =
             PrFlow.run(issue(), workspace_path,
               branch_name: "symphony/pri-170-owned-pr",
               command_runner: command_runner,
               tracker_update: tracker_update
             )

    assert result.changed_files == ["lib/example.ex", "test/example_test.exs"]
    assert result.commit_sha == "abc123"
    assert result.pr_url == "https://github.com/acme/repo/pull/123"
    assert_received {:tracker_update, "issue-pr-flow", "In Review"}
  end

  test "push failure does not update tracker state" do
    parent = self()
    workspace_path = Path.join(System.tmp_dir!(), "symphony_pr_flow_push_test")
    File.rm_rf!(workspace_path)
    File.mkdir_p!(workspace_path)
    setup_completion_report(workspace_path, ["lib/example.ex"])

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

    tracker_update = fn issue_id, state_name ->
      send(parent, {:tracker_update, issue_id, state_name})
      :ok
    end

    assert {:error, {:git_push_failed, 1, "network failed"}} =
             PrFlow.run(issue(), workspace_path,
               branch_name: "symphony/pri-170-owned-pr",
               command_runner: command_runner,
               tracker_update: tracker_update
             )

    refute_received {:tracker_update, _, _}
  end

  test "PR creation failure keeps branch and commit but does not update tracker state" do
    parent = self()
    workspace_path = Path.join(System.tmp_dir!(), "symphony_pr_flow_pr_test")
    File.rm_rf!(workspace_path)
    File.mkdir_p!(workspace_path)
    setup_completion_report(workspace_path, ["lib/example.ex"])

    command_runner = fn cmd, args, opts ->
      send(parent, {:command, cmd, args, opts})

      case {cmd, args} do
        {"git", ["status", "--porcelain"]} -> {" M lib/example.ex\n", 0}
        {"git", ["add", "--", "lib/example.ex"]} -> {"", 0}
        {"git", ["commit", "-m", _message]} -> {"committed", 0}
        {"git", ["rev-parse", "HEAD"]} -> {"abc123\n", 0}
        {"git", ["push", "-u", "origin", "symphony/pri-170-owned-pr"]} -> {"pushed", 0}
        {"gh", ["pr", "create" | _rest]} -> {"authentication failed", 1}
      end
    end

    tracker_update = fn issue_id, state_name ->
      send(parent, {:tracker_update, issue_id, state_name})
      :ok
    end

    assert {:error, {:gh_pr_create_failed, 1, "authentication failed"}} =
             PrFlow.run(issue(), workspace_path,
               branch_name: "symphony/pri-170-owned-pr",
               command_runner: command_runner,
               tracker_update: tracker_update
             )

    assert_received {:command, "git", ["push", "-u", "origin", "symphony/pri-170-owned-pr"], _}
    refute_received {:tracker_update, _, _}
  end

  test "forbidden changed paths fail closed before staging" do
    parent = self()
    workspace_path = Path.join(System.tmp_dir!(), "symphony_pr_flow_forbidden_test")
    File.rm_rf!(workspace_path)
    File.mkdir_p!(workspace_path)
    setup_completion_report(workspace_path, ["lib/example.ex"])

    command_runner = fn cmd, args, opts ->
      send(parent, {:command, cmd, args, opts})

      case {cmd, args} do
        {"git", ["status", "--porcelain"]} -> {"?? .trae/documents/plan.md\n M lib/example.ex\n", 0}
      end
    end

    assert {:error, {:forbidden_changed_file, ".trae/documents/plan.md"}} =
             PrFlow.run(issue(), workspace_path,
               branch_name: "symphony/pri-170-owned-pr",
               command_runner: command_runner,
               tracker_update: fn _, _ -> :ok end
             )

    refute_received {:command, "git", ["add" | _], _}
  end
end

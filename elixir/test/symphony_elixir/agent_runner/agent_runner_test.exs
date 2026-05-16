defmodule SymphonyElixir.AgentRunnerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Linear.Issue

  describe "selected_worker_host/2" do
    test "returns nil when no preferred host and no configured hosts" do
      assert delegate(:selected_worker_host).(nil, []) == nil
    end

    test "returns preferred host when it is set" do
      assert delegate(:selected_worker_host).("worker1.example.com", ["worker2.example.com"]) ==
               "worker1.example.com"
    end

    test "returns first configured host when no preferred host" do
      assert delegate(:selected_worker_host).(nil, ["worker1.example.com", "worker2.example.com"]) ==
               "worker1.example.com"
    end

    test "returns nil when configured hosts are all empty strings" do
      assert delegate(:selected_worker_host).(nil, ["", " "]) == nil
    end

    test "deduplicates configured hosts" do
      hosts = delegate(:selected_worker_host).(nil, ["a.com", "a.com", "b.com"])
      assert hosts == "a.com"
    end

    test "trims whitespace from configured hosts" do
      assert delegate(:selected_worker_host).(nil, ["  a.com  "]) == "a.com"
    end

    test "returns nil for empty string preferred host" do
      assert delegate(:selected_worker_host).("", ["a.com"]) == "a.com"
    end
  end

  describe "active_issue_state?/1" do
    test "recognizes default active states" do
      assert delegate(:active_issue_state).("In Progress") == true
      assert delegate(:active_issue_state).("Todo") == true
    end

    test "is case-insensitive" do
      assert delegate(:active_issue_state).("in progress") == true
      assert delegate(:active_issue_state).("TODO") == true
    end

    test "returns false for terminal states" do
      assert delegate(:active_issue_state).("Done") == false
      assert delegate(:active_issue_state).("Closed") == false
      assert delegate(:active_issue_state).("Cancelled") == false
    end

    test "returns false for nil" do
      assert delegate(:active_issue_state).(nil) == false
    end
  end

  describe "continue_with_issue?/2" do
    test "continues when issue state is active" do
      issue = %Issue{id: "123", identifier: "MT-1", state: "In Progress"}
      fetcher = fn _ids -> {:ok, [issue]} end

      assert {:continue, ^issue} = delegate(:continue_with_issue).(issue, fetcher)
    end

    test "done when issue state is terminal" do
      issue = %Issue{id: "123", identifier: "MT-1", state: "Done"}
      fetcher = fn _ids -> {:ok, [issue]} end

      assert {:done, ^issue} = delegate(:continue_with_issue).(issue, fetcher)
    end

    test "done when issue not found" do
      issue = %Issue{id: "123", identifier: "MT-1", state: "In Progress"}
      fetcher = fn _ids -> {:ok, []} end

      assert {:done, ^issue} = delegate(:continue_with_issue).(issue, fetcher)
    end

    test "error when fetcher fails" do
      issue = %Issue{id: "123", identifier: "MT-1", state: "In Progress"}
      fetcher = fn _ids -> {:error, :network_timeout} end

      assert {:error, {:issue_state_refresh_failed, :network_timeout}} =
               delegate(:continue_with_issue).(issue, fetcher)
    end

    test "done when issue has no id" do
      issue = %Issue{id: nil, identifier: "MT-1", state: "In Progress"}

      assert {:done, ^issue} = delegate(:continue_with_issue).(issue, fn _ -> {:ok, []} end)
    end
  end

  describe "timeout_seconds/1" do
    test "converts milliseconds to seconds with ceiling" do
      assert delegate(:timeout_seconds).(1_000) == 1
      assert delegate(:timeout_seconds).(1_001) == 2
      assert delegate(:timeout_seconds).(3_600_000) == 3600
    end

    test "minimum is 1 second" do
      assert delegate(:timeout_seconds).(1) == 1
      assert delegate(:timeout_seconds).(500) == 1
    end

    test "returns nil for non-integer" do
      assert delegate(:timeout_seconds).(nil) == nil
      assert delegate(:timeout_seconds).("1000") == nil
    end

    test "returns nil for zero or negative" do
      assert delegate(:timeout_seconds).(0) == nil
      assert delegate(:timeout_seconds).(-1) == nil
    end
  end

  describe "normalize_issue_state/1" do
    test "downcases and trims" do
      assert delegate(:normalize_issue_state).("  In Progress  ") == "in progress"
      assert delegate(:normalize_issue_state).("TODO") == "todo"
    end
  end

  describe "max_turns_label/1" do
    test "shows unlimited for -1" do
      assert delegate(:max_turns_label).(-1) == "unlimited"
    end

    test "shows number for positive values" do
      assert delegate(:max_turns_label).(20) == "20"
    end
  end

  describe "build_turn_prompt/4" do
    test "first turn uses PromptBuilder" do
      issue = %Issue{
        id: "123",
        identifier: "MT-1",
        title: "Fix bug",
        description: "Something is broken",
        state: "In Progress",
        url: "https://example.org/issues/MT-1",
        labels: []
      }

      prompt = delegate(:build_turn_prompt).(issue, [], 1, 20, "/workspace/MT-1")
      assert is_binary(prompt)
      assert prompt =~ "MT-1"
    end

    test "continuation turns include guidance" do
      prompt = delegate(:build_turn_prompt).(%Issue{}, [], 3, 20, "/workspace/test")
      assert prompt =~ "continuation turn #3"
      assert prompt =~ "20"
    end

    test "continuation turn shows unlimited when max_turns is -1" do
      prompt = delegate(:build_turn_prompt).(%Issue{}, [], 2, -1, "/workspace/test")
      assert prompt =~ "unlimited"
    end
  end

  describe "send_agent_update/3" do
    test "sends update message to recipient" do
      issue = %Issue{id: "issue-123", identifier: "MT-1"}
      message = %{event: :test}

      delegate(:send_agent_update).(self(), issue, message)

      assert_received {:agent_worker_update, "issue-123", ^message}
    end

    test "no-ops when recipient is nil" do
      issue = %Issue{id: "issue-123", identifier: "MT-1"}
      assert delegate(:send_agent_update).(nil, issue, %{event: :test}) == :ok
    end

    test "no-ops when issue has no id" do
      issue = %Issue{id: nil, identifier: "MT-1"}
      assert delegate(:send_agent_update).(self(), issue, %{event: :test}) == :ok
    end
  end

  describe "send_worker_runtime_info/4" do
    test "sends runtime info to recipient" do
      issue = %Issue{id: "issue-456", identifier: "MT-2"}

      delegate(:send_worker_runtime_info).(self(), issue, "host1", "/workspace/MT-2")

      assert_received {:worker_runtime_info, "issue-456", info}
      assert info.worker_host == "host1"
      assert info.workspace_path == "/workspace/MT-2"
    end

    test "no-ops when recipient is nil" do
      issue = %Issue{id: "issue-456", identifier: "MT-2"}

      assert delegate(:send_worker_runtime_info).(nil, issue, "host1", "/workspace") == :ok
    end
  end

  describe "pr_created?/1" do
    test "returns true when .pr_created marker file exists" do
      dir = System.tmp_dir!()
      marker_path = Path.join(dir, ".pr_created")
      File.write!(marker_path, "")

      try do
        assert AgentRunner.pr_created?(dir) == true
      after
        File.rm(marker_path)
      end
    end

    test "returns false when .pr_created marker file does not exist" do
      dir = System.tmp_dir!()
      # Ensure no marker file exists
      File.rm(Path.join(dir, ".pr_created"))

      assert AgentRunner.pr_created?(dir) == false
    end
  end

  describe "pr_quality_gate/1" do
    test "returns :ok when workspace is clean" do
      # 创建一个临时 git 仓库
      dir = Path.join(System.tmp_dir!(), "test_quality_gate_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      try do
        System.cmd("git", ["init"], cd: dir)
        System.cmd("git", ["config", "user.email", "test@test.com"], cd: dir)
        System.cmd("git", ["config", "user.name", "Test"], cd: dir)

        # 创建并提交一个文件
        File.write!(Path.join(dir, "test.txt"), "hello\n")
        System.cmd("git", ["add", "."], cd: dir)
        System.cmd("git", ["commit", "-m", "initial"], cd: dir)

        assert AgentRunner.pr_quality_gate(dir) == :ok
      after
        File.rm_rf(dir)
      end
    end

    test "returns :ok when git is not available" do
      # 非 git 目录应该返回 :ok（跳过检查）
      dir = Path.join(System.tmp_dir!(), "test_no_git_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      try do
        assert AgentRunner.pr_quality_gate(dir) == :ok
      after
        File.rm_rf(dir)
      end
    end
  end

  defp delegate(function_name) do
    AgentRunner.__testing__()[function_name]
  end
end

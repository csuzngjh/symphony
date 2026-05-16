defmodule SymphonyElixir.Review.RunnerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Review.Runner

  defmodule FakeExecutor do
    def exec(_workspace_path, _prompt, _timeout_ms) do
      {:ok, ~s({"score":85,"summary":"Good code","details":"Well structured","business_summary":"Code looks clean"})}
    end
  end

  defmodule SlowExecutor do
    def exec(_workspace_path, _prompt, timeout_ms) do
      Process.sleep(timeout_ms + 100)
      {:ok, ~s({"score":50,"summary":"Slow","details":"Took too long","business_summary":"Late"})}
    end
  end

  defmodule PartialFailureExecutor do
    def exec(_workspace_path, prompt, _timeout_ms) do
      if String.contains?(prompt, "安全工程师") do
        {:error, "security scan failed"}
      else
        {:ok, ~s({"score":80,"summary":"OK","details":"Works","business_summary":"Good"})}
      end
    end
  end

  defmodule SelectiveTimeoutExecutor do
    def exec(_workspace_path, prompt, timeout_ms) do
      if String.contains?(prompt, "安全") do
        Process.sleep(timeout_ms + 200)
      end

      {:ok, ~s({"score":75,"summary":"OK","details":"Done","business_summary":"Fine"})}
    end
  end

  setup do
    config = %SymphonyElixir.Config.Schema{
      review: %SymphonyElixir.Config.Schema.Review{
        enabled: true,
        timeout_ms: 100,
        max_concurrent: 4
      }
    }

    issue = %{id: "TEST-1"}
    {:ok, config: config, issue: issue}
  end

  describe "run/4" do
    test "four dimensions run with fake executor", %{config: config, issue: issue} do
      assert {:ok, results} = Runner.run(issue, "/tmp/ws", config, executor: FakeExecutor)
      assert length(results) == 4

      for result <- results do
        assert result.status == :success
        assert is_integer(result.score)
        assert is_binary(result.summary)
      end
    end

    test "dimension names are preserved", %{config: config, issue: issue} do
      assert {:ok, results} = Runner.run(issue, "/tmp/ws", config, executor: FakeExecutor)
      names = Enum.map(results, & &1.dimension) |> Enum.sort()
      assert names == [:business_compliance, :code_quality, :security_audit, :test_coverage]
    end

    test "one timeout does not block others", %{config: config, issue: issue} do
      assert {:ok, results} = Runner.run(issue, "/tmp/ws", config, executor: SlowExecutor)
      assert length(results) == 4

      timeout_count = Enum.count(results, &(&1.status == :timeout))
      assert timeout_count > 0
    end

    test "one failure is captured in results", %{config: config, issue: issue} do
      assert {:ok, results} = Runner.run(issue, "/tmp/ws", config, executor: PartialFailureExecutor)
      assert length(results) == 4

      failure_count = Enum.count(results, &(&1.status == :failure))
      assert failure_count == 1

      success_count = Enum.count(results, &(&1.status == :success))
      assert success_count == 3
    end

    test "all results returned even with partial failures", %{config: config, issue: issue} do
      assert {:ok, results} = Runner.run(issue, "/tmp/ws", config, executor: PartialFailureExecutor)

      statuses = Enum.map(results, & &1.status)
      assert :failure in statuses
      assert :success in statuses
      assert length(results) == 4
    end

    test "results are returned in {:ok, results} tuple", %{config: config, issue: issue} do
      assert {:ok, _results} = Runner.run(issue, "/tmp/ws", config, executor: FakeExecutor)
    end

    test "uses max_concurrent from config", %{config: config, issue: issue} do
      config_with_limit = put_in(config.review.max_concurrent, 1)
      assert {:ok, results} = Runner.run(issue, "/tmp/ws", config_with_limit, executor: FakeExecutor)
      assert length(results) == 4
    end
  end
end
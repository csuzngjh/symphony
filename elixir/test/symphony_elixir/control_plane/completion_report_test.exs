defmodule SymphonyElixir.ControlPlane.CompletionReportTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ControlPlane.CompletionReport

  defp tmp_workspace do
    Path.join(System.tmp_dir!(), "symphony-completion-report-#{System.unique_integer([:positive])}")
  end

  defp write_completion_json(dir, data) do
    symphony_dir = Path.join(dir, ".symphony")
    File.mkdir_p!(symphony_dir)
    File.write!(Path.join(symphony_dir, "agent-completion.json"), Jason.encode!(data))
  end

  defp write_completion_raw(dir, content) do
    symphony_dir = Path.join(dir, ".symphony")
    File.mkdir_p!(symphony_dir)
    File.write!(Path.join(symphony_dir, "agent-completion.json"), content)
  end

  describe "read/1" do
    test "valid file" do
      dir = tmp_workspace()
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      report = %{
        "status" => "ready_for_review",
        "changed_files" => ["lib/a.ex"],
        "tests" => [%{"command" => "mix test", "result" => "passed"}]
      }

      write_completion_json(dir, report)

      assert {:ok, read_report} = CompletionReport.read(dir)
      assert read_report["status"] == "ready_for_review"
      assert read_report["changed_files"] == ["lib/a.ex"]
      assert length(read_report["tests"]) == 1
    end

    test "missing file" do
      dir = tmp_workspace()
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:error, :missing_completion_report} = CompletionReport.read(dir)
    end

    test "invalid JSON" do
      dir = tmp_workspace()
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      write_completion_raw(dir, "not valid json {{{")

      assert {:error, :invalid_completion_report} = CompletionReport.read(dir)
    end
  end

  describe "validate/2" do
    test "valid report" do
      report = %{
        "status" => "ready_for_review",
        "changed_files" => ["lib/a.ex", "test/b_test.exs"],
        "tests" => [%{"command" => "mix test", "result" => "passed"}]
      }

      opts = [changed_files: ["lib/a.ex", "test/b_test.exs"]]

      assert {:ok, ^report} = CompletionReport.validate(report, opts)
    end

    test "status=blocked" do
      report = %{
        "status" => "blocked",
        "changed_files" => ["lib/a.ex"],
        "tests" => [%{"command" => "mix test", "result" => "passed"}]
      }

      opts = [changed_files: ["lib/a.ex"]]

      assert {:error, {:agent_blocked, ^report}} = CompletionReport.validate(report, opts)
    end

    test "changed_files mismatch" do
      report = %{
        "status" => "ready_for_review",
        "changed_files" => ["lib/a.ex"],
        "tests" => [%{"command" => "mix test", "result" => "passed"}]
      }

      opts = [changed_files: ["lib/a.ex", "lib/c.ex"]]

      assert {:error, :completion_changed_files_mismatch} = CompletionReport.validate(report, opts)
    end

    test "empty tests" do
      report = %{
        "status" => "ready_for_review",
        "changed_files" => ["lib/a.ex"],
        "tests" => []
      }

      opts = [changed_files: ["lib/a.ex"]]

      assert {:error, :completion_no_tests} = CompletionReport.validate(report, opts)
    end

    test "invalid status" do
      report = %{
        "status" => "unknown",
        "changed_files" => ["lib/a.ex"],
        "tests" => [%{"command" => "mix test", "result" => "passed"}]
      }

      opts = [changed_files: ["lib/a.ex"]]

      assert {:error, {:invalid_status, "unknown"}} = CompletionReport.validate(report, opts)
    end
  end

  describe "validate_changed_files/2" do
    test "matching" do
      report = %{"changed_files" => ["lib/a.ex", "test/b_test.exs"]}
      opts = [changed_files: ["lib/a.ex", "test/b_test.exs"]]

      assert :ok = CompletionReport.validate_changed_files(report, opts)
    end

    test "mismatch" do
      report = %{"changed_files" => ["lib/a.ex"]}
      opts = [changed_files: ["lib/a.ex", "lib/c.ex"]]

      assert {:error, :completion_changed_files_mismatch} =
               CompletionReport.validate_changed_files(report, opts)
    end

    test "report has extra files" do
      report = %{"changed_files" => ["lib/a.ex", "lib/extra.ex"]}
      opts = [changed_files: ["lib/a.ex"]]

      assert {:error, :completion_changed_files_mismatch} =
               CompletionReport.validate_changed_files(report, opts)
    end
  end

  describe "validate_tests/1" do
    test "valid" do
      report = %{"tests" => [%{"command" => "mix test", "result" => "passed"}]}

      assert :ok = CompletionReport.validate_tests(report)
    end

    test "empty" do
      report = %{"tests" => []}

      assert {:error, :completion_no_tests} = CompletionReport.validate_tests(report)
    end

    test "entry without command" do
      report = %{"tests" => [%{"result" => "passed"}]}

      assert {:error, :completion_no_tests} = CompletionReport.validate_tests(report)
    end
  end
end

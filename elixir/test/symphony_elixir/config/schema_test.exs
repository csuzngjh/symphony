defmodule SymphonyElixir.Config.SchemaTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema

  test "workspace_activity_scan_interval_ms defaults to 15_000" do
    config = Config.settings!()
    assert config.agent.workspace_activity_scan_interval_ms == 15_000
  end

  test "workspace_activity_scan_interval_ms can be overridden via workflow config" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_workspace_activity_scan_interval_ms: 30_000
    )

    config = Config.settings!()
    assert config.agent.workspace_activity_scan_interval_ms == 30_000
  end

  test "workspace_activity_scan_interval_ms rejects non-positive values" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_workspace_activity_scan_interval_ms: 0
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.workspace_activity_scan_interval_ms"
  end

  test "workspace_activity_scan_interval_ms rejects non-integer values" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_workspace_activity_scan_interval_ms: "bad"
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.workspace_activity_scan_interval_ms"
  end

  test "Schema.parse includes workspace_activity_scan_interval_ms with default" do
    assert {:ok, settings} = Schema.parse(%{agent: %{}})
    assert settings.agent.workspace_activity_scan_interval_ms == 15_000
  end

  test "tracker active_states includes Auto Review by default" do
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert "Auto Review" in settings.tracker.active_states
  end

  describe "review config" do
    test "review defaults when not specified" do
      assert {:ok, settings} = Schema.parse(%{})
      assert settings.review.enabled == false
      assert settings.review.timeout_ms == 300_000
      assert settings.review.max_concurrent == 4
    end

    test "review config can be set" do
      assert {:ok, settings} = Schema.parse(%{review: %{enabled: true, timeout_ms: 60_000, max_concurrent: 2}})
      assert settings.review.enabled == true
      assert settings.review.timeout_ms == 60_000
      assert settings.review.max_concurrent == 2
    end

    test "review rejects zero timeout_ms" do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{review: %{timeout_ms: 0}})
      assert message =~ "review.timeout_ms"
    end

    test "review rejects negative timeout_ms" do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{review: %{timeout_ms: -1}})
      assert message =~ "review.timeout_ms"
    end

    test "review rejects zero max_concurrent" do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{review: %{max_concurrent: 0}})
      assert message =~ "review.max_concurrent"
    end

    test "review rejects negative max_concurrent" do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{review: %{max_concurrent: -1}})
      assert message =~ "review.max_concurrent"
    end
  end
end

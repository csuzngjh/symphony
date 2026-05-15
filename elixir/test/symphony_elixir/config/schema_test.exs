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
end

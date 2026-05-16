defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  def normalize_path_for_platform(path) when is_binary(path) do
    path
    |> String.replace("\\", "/")
    |> String.downcase()
  end

  def symlink_supported? do
    case :os.type() do
      {:unix, _} -> true
      {:win32, _} -> probe_symlink_on_windows()
    end
  end

  defp probe_symlink_on_windows do
    test_dir = Path.join(System.tmp_dir!(), "symphony-symlink-probe-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(test_dir)
      target = Path.join(test_dir, "target")
      link = Path.join(test_dir, "link")
      File.mkdir_p!(target)
      case File.ln_s(target, link) do
        :ok -> true
        {:error, _} -> false
      end
    rescue
      _ -> false
    after
      File.rm_rf(test_dir)
    end
  end

  def read_text_normalized(path) do
    path
    |> File.read!()
    |> String.replace("\r\n", "\n")
  end

  def posix_path(path) when is_binary(path) do
    String.replace(path, "\\", "/")
  end

  def git_available? do
    case System.cmd("git", ["--version"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Cross-platform temporary path builder.
  On all platforms, returns `#{System.tmp_dir!()}/<name>`.
  """
  def tmp_path(name) when is_binary(name) do
    Path.join(System.tmp_dir!(), name)
  end

  @doc """
  Returns `true` when running on Windows (`{:win32, _}`).
  """
  def windows? do
    match?({:win32, _}, :os.type())
  end

  @doc """
  Returns the remote shell command template suitable for the current platform
  when targeting localhost (SSH tests).  On POSIX: "bash -lc <cmd>".
  On Windows remote targets, the template can be overridden via
  `Application.put_env(:symphony_elixir, :remote_shell_template, ...)`.
  """
  def remote_shell_template do
    Application.get_env(:symphony_elixir, :remote_shell_template, "bash -lc %s")
  end

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [
          write_workflow_file!: 1,
          write_workflow_file!: 2,
          restore_env: 2,
          stop_default_http_server: 0,
          normalize_path_for_platform: 1,
          symlink_supported?: 0,
          read_text_normalized: 1,
          git_available?: 0,
          posix_path: 1,
          tmp_path: 1,
          windows?: 0,
          remote_shell_template: 0
        ]

      setup do
        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        if Process.whereis(SymphonyElixir.WorkflowStore) do
          try do
            SymphonyElixir.WorkflowStore.force_reload()
          catch
            :exit, _reason -> :ok
          end
        end
        stop_default_http_server()

        on_exit(fn ->
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    File.write!(path, workflow)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def stop_default_http_server do
    if pid = Process.whereis(SymphonyElixir.Supervisor) do
      if Process.alive?(pid) do
        case Supervisor.which_children(SymphonyElixir.Supervisor) do
          children when is_list(children) ->
            case Enum.find(children, fn
                   {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
                   _child -> false
                 end) do
              {SymphonyElixir.HttpServer, child_pid, _type, _modules} when is_pid(child_pid) ->
                if Process.alive?(child_pid) do
                  Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)
                  Process.exit(child_pid, :normal)
                end

              _ ->
                :ok
            end

          _ ->
            :ok
        end
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_slug: "project",
          tracker_assignee: nil,
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          agent_command: "claude",
          agent_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          agent_thread_sandbox: "workspace-write",
          agent_turn_sandbox_policy: nil,
          agent_turn_timeout_ms: 3_600_000,
          agent_read_timeout_ms: 5_000,
          agent_stall_timeout_ms: 300_000,
          agent_workspace_activity_scan_interval_ms: 15_000,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          server_port: nil,
          server_host: nil,
          review_enabled: false,
          review_timeout_ms: 300_000,
          review_max_concurrent: 4,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_issue_identifiers = Keyword.get(config, :tracker_issue_identifiers)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    continuation_retry_delay_ms = Keyword.get(config, :continuation_retry_delay_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    agent_command = Keyword.get(config, :agent_command)
    agent_approval_policy = Keyword.get(config, :agent_approval_policy)
    agent_thread_sandbox = Keyword.get(config, :agent_thread_sandbox)
    agent_turn_sandbox_policy = Keyword.get(config, :agent_turn_sandbox_policy)
    agent_turn_timeout_ms = Keyword.get(config, :agent_turn_timeout_ms)
    agent_read_timeout_ms = Keyword.get(config, :agent_read_timeout_ms)
    agent_stall_timeout_ms = Keyword.get(config, :agent_stall_timeout_ms)
    agent_workspace_activity_scan_interval_ms = Keyword.get(config, :agent_workspace_activity_scan_interval_ms)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    review_enabled = Keyword.get(config, :review_enabled)
    review_timeout_ms = Keyword.get(config, :review_timeout_ms)
    review_max_concurrent = Keyword.get(config, :review_max_concurrent)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_key: #{yaml_value(tracker_api_token)}",
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  issue_identifiers: #{yaml_value(tracker_issue_identifiers)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  continuation_retry_delay_ms: #{yaml_value(continuation_retry_delay_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "  command: #{yaml_value(agent_command)}",
        "  approval_policy: #{yaml_value(agent_approval_policy)}",
        "  thread_sandbox: #{yaml_value(agent_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(agent_turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(agent_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(agent_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(agent_stall_timeout_ms)}",
        "  workspace_activity_scan_interval_ms: #{yaml_value(agent_workspace_activity_scan_interval_ms)}",
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        server_yaml(server_port, server_host),
        review_yaml(review_enabled, review_timeout_ms, review_max_concurrent),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp yaml_value(value) when is_binary(value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"" <> escaped <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp review_yaml(enabled, timeout_ms, max_concurrent) do
    [
      "review:",
      "  enabled: #{yaml_value(enabled)}",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      "  max_concurrent: #{yaml_value(max_concurrent)}"
    ]
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end

defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            blocked: length(snapshot.blocked)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          blocked: Enum.map(snapshot.blocked, &blocked_entry_payload/1),
          agent_totals: snapshot.agent_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        blocked = Enum.find(snapshot.blocked, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(blocked) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, blocked)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, blocked) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, blocked),
      status: issue_status(running, retry, blocked),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry, blocked),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      blocked: blocked && blocked_issue_payload(blocked),
      logs: %{
        agent_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry, blocked),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (blocked && blocked.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(nil, nil, nil), do: "unknown"
  defp issue_status(%{}, nil, nil), do: "running"
  defp issue_status(nil, %{}, nil), do: "retrying"
  defp issue_status(nil, nil, %{}), do: "blocked"
  defp issue_status(%{}, %{}, _), do: "running"
  defp issue_status(%{}, _, %{}), do: "running"
  defp issue_status(_, %{}, %{}), do: "retrying"
  defp issue_status(_, _, _), do: "unknown"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      attempt_status: Map.get(entry, :attempt_status, :running),
      attempt_id: Map.get(entry, :attempt_id),
      session_name: Map.get(entry, :session_name),
      phase: Map.get(entry, :phase),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      acpx_record_id: Map.get(entry, :acpx_record_id),
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_agent_event,
      last_raw_event_at: iso8601(Map.get(entry, :last_raw_event_at)),
      last_raw_preview: Map.get(entry, :last_raw_preview),
      last_message: summarize_message(entry.last_agent_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_agent_timestamp),
      progress_source: Map.get(entry, :progress_source, "none"),
      last_progress_at: iso8601(latest_progress_at(entry)),
      last_workspace_activity_at: iso8601(Map.get(entry, :last_workspace_activity_at)),
      process_alive: process_alive?(entry),
      tokens: %{
        input_tokens: entry.agent_input_tokens,
        output_tokens: entry.agent_output_tokens,
        total_tokens: entry.agent_total_tokens,
        cached_read_tokens: Map.get(entry, :agent_cached_read_tokens, 0),
        cached_write_tokens: Map.get(entry, :agent_cached_write_tokens, 0)
      },
      consecutive_parser_errors: Map.get(entry, :consecutive_parser_errors, 0)
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      session_name: Map.get(running, :session_name),
      acpx_record_id: Map.get(running, :acpx_record_id),
      attempt_id: Map.get(running, :attempt_id),
      attempt_status: Map.get(running, :attempt_status, :running),
      phase: Map.get(running, :phase),
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_agent_event,
      last_raw_event_at: iso8601(Map.get(running, :last_raw_event_at)),
      last_raw_preview: Map.get(running, :last_raw_preview),
      last_message: summarize_message(running.last_agent_message),
      last_event_at: iso8601(running.last_agent_timestamp),
      progress_source: Map.get(running, :progress_source, "none"),
      last_progress_at: iso8601(latest_progress_at(running)),
      last_workspace_activity_at: iso8601(Map.get(running, :last_workspace_activity_at)),
      process_alive: process_alive?(running),
      consecutive_parser_errors: Map.get(running, :consecutive_parser_errors, 0),
      tokens: %{
        input_tokens: running.agent_input_tokens,
        output_tokens: running.agent_output_tokens,
        total_tokens: running.agent_total_tokens,
        cached_read_tokens: Map.get(running, :agent_cached_read_tokens, 0),
        cached_write_tokens: Map.get(running, :agent_cached_write_tokens, 0)
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp blocked_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      workspace_path: entry.workspace_path,
      reason: entry.reason,
      dirty_files: entry.dirty_files,
      last_error: entry.last_error,
      blocked_at: iso8601(entry.blocked_at)
    }
  end

  defp blocked_issue_payload(blocked) do
    %{
      reason: Map.get(blocked, :reason),
      workspace_path: Map.get(blocked, :workspace_path),
      dirty_files: Map.get(blocked, :dirty_files, []),
      last_error: Map.get(blocked, :last_error),
      blocked_at: iso8601(Map.get(blocked, :blocked_at))
    }
  end

  defp workspace_path(issue_identifier, running, retry, blocked) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (blocked && Map.get(blocked, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_payload(running) do
    [
      %{
    at: iso8601(running.last_agent_timestamp),
    event: running.last_agent_event,
    message: summarize_message(running.last_agent_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_agent_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  defp latest_progress_at(running) do
    [running[:last_raw_event_at], running[:last_workspace_activity_at], running[:last_process_seen_at]]
    |> Enum.filter(&is_struct(&1, DateTime))
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp process_alive?(running) do
    case Map.get(running, :pid) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end
end

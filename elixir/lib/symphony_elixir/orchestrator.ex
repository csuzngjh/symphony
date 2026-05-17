defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to ACPX-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{AgentRunner, Config, StatusDashboard, Tracker, Workspace, WorkspaceActivity}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Review.{Runner, Reporter}

  @default_continuation_retry_delay_ms 300_000
  @failure_retry_base_ms 10_000
  @max_completed_set_size 1_000
  @blocked_ttl_seconds 86_400
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @attempt_shutdown_timeout_ms 15_000
  @empty_agent_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    cached_read_tokens: 0,
    cached_write_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      :acpx_session_root,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      agent_totals: nil,
      agent_rate_limits: nil,
      blocked: %{},
      reviews: %{}
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      agent_totals: @empty_agent_totals,
      agent_rate_limits: nil,
      acpx_session_root: Keyword.get(opts, :acpx_session_root)
    }

    run_terminal_workspace_cleanup()
    state = schedule_tick(state, 0)

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    me = self()
    state = refresh_runtime_config(state)
    poll_token = make_ref()

    # Offload slow I/O (Linear fetch, workspace scan, git check) to a Task
    # so the GenServer mailbox remains responsive for snapshot/status calls.
    Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      poll_result =
        try do
          do_poll_cycle(state, me)
        catch
          kind, reason ->
            Logger.error("Poll cycle failed with #{kind}: #{inspect(reason)}")
            state
        end

      send(me, {:poll_cycle_completed, poll_token, poll_result})
    end)

    state = %{state | poll_check_in_progress: true}
    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:poll_cycle_completed, _poll_token, poll_result}, state) do
    state = apply_poll_result(state, poll_result)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running, reviews: reviews} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        handle_review_down(ref, reason, reviews, state)

      issue_id ->
        running_entry = Map.get(running, issue_id)
        status = Map.get(running_entry, :status, :running)
        session_id = running_entry_session_id(running_entry)

        force_kill_ref = Map.get(running_entry || %{}, :force_kill_timer_ref)
        if is_reference(force_kill_ref), do: Process.cancel_timer(force_kill_ref)

        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)

        state =
          cond do
            status == :terminating ->
              workspace_path = Map.get(running_entry, :workspace_path)
              identifier = running_entry.identifier

              case check_workspace_dirty(workspace_path, Map.get(running_entry, :worker_host)) do
                {:dirty, dirty_files} ->
                  Logger.warning("Issue blocked after stall: issue_id=#{issue_id} issue_identifier=#{identifier} workspace_path=#{workspace_path} dirty_files=#{inspect(dirty_files)}")

                  block_issue(state, issue_id, %{
                    identifier: identifier,
                    workspace_path: workspace_path,
                    reason: "workspace_dirty_after_stall",
                    dirty_files: dirty_files,
                    last_error: "stalled/terminated: #{inspect(reason)}"
                  }, DateTime.utc_now())

                {:unknown, _} when workspace_path != nil ->
                  Logger.warning("Issue blocked after stall: issue_id=#{issue_id} issue_identifier=#{identifier} workspace_path=#{workspace_path} reason=workspace_unknown")

                  block_issue(state, issue_id, %{
                    identifier: identifier,
                    workspace_path: workspace_path,
                    reason: "workspace_unknown_after_stall",
                    dirty_files: [],
                    last_error: "stalled/terminated: #{inspect(reason)}"
                  }, DateTime.utc_now())

                _ ->
                  next_attempt = next_retry_attempt_from_running(running_entry)

                  Logger.warning("Terminated attempt confirmed dead for issue_id=#{issue_id} session_id=#{session_id}; scheduling retry")

                  schedule_issue_retry(state, issue_id, next_attempt, %{
                    identifier: identifier,
                    error: "stalled/terminated: #{inspect(reason)}",
                    worker_host: Map.get(running_entry, :worker_host),
                    workspace_path: workspace_path
                  })
              end

            reason == :normal ->
              Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

              state
              |> complete_issue(issue_id)
              |> schedule_issue_retry(issue_id, 1, %{
                identifier: running_entry.identifier,
                delay_type: :continuation,
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path)
              })

            true ->
              next_attempt = next_retry_attempt_from_running(running_entry)
              error_str = "agent exited: #{inspect(reason)}"

              if deterministic_infra_failure?(reason) and is_integer(next_attempt) and next_attempt >= 2 do
                Logger.warning("Deterministic infra failure for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; blocking instead of retry")

                block_issue(state, issue_id, %{
                  identifier: running_entry.identifier,
                  workspace_path: Map.get(running_entry, :workspace_path),
                  reason: infra_failure_block_reason(reason),
                  dirty_files: [],
                  last_error: error_str
                }, DateTime.utc_now())
              else
                Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

                schedule_issue_retry(state, issue_id, next_attempt, %{
                  identifier: running_entry.identifier,
                  error: error_str,
                  worker_host: Map.get(running_entry, :worker_host),
                  workspace_path: Map.get(running_entry, :workspace_path)
                })
              end
          end

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:agent_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_agent_update(running_entry, update)

        state =
          state
          |> apply_agent_token_delta(token_delta)
          |> apply_agent_rate_limits(update)
          |> then(&%{&1 | running: Map.put(&1.running, issue_id, updated_running_entry)})

        state = maybe_block_on_boundary_violation(state, issue_id, updated_running_entry, update)

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:agent_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info({:force_kill_attempt, issue_id}, %{running: running} = state) do
    case Map.get(running, issue_id) do
      %{status: :terminating} = entry ->
        Logger.warning("Force-killing attempt that did not shutdown in time: issue_id=#{issue_id}")

        pid = Map.get(entry, :pid)
        if is_pid(pid) do
          Process.exit(pid, :kill)
        end

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:review_completed, %Issue{id: issue_id} = issue, result}, %State{reviews: reviews} = state) do
    case Map.get(reviews, issue_id) do
      %{ref: ref} when is_reference(ref) ->
        Process.demonitor(ref, [:flush])

      _ ->
        :ok
    end

    state = %{state | reviews: Map.delete(reviews, issue_id)}
    handle_review_result(issue, result)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp do_poll_cycle(%State{} = state, orchestrator_pid) do
    # Validate config first - fail fast if missing required settings
    with :ok <- Config.validate!() do
      state = reconcile_running_issues(state)

      if available_slots(state) > 0 do
        case Tracker.fetch_candidate_issues() do
          {:ok, issues} ->
            Logger.debug("Poll fetched #{length(issues)} candidate issues")
            choose_issues(issues, state, orchestrator_pid)

          {:error, reason} ->
            Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
            state
        end
      else
        state
      end
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")
        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")
        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state
    end
  end

  defp apply_poll_result(state, %State{} = new_state) do
    %{state |
      running: new_state.running,
      claimed: new_state.claimed,
      retry_attempts: new_state.retry_attempts,
      blocked: new_state.blocked,
      agent_totals: new_state.agent_totals,
      reviews: new_state.reviews
    }
  end

  defp apply_poll_result(state, _result) do
    state
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    state = expire_blocked_entries(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      auto_review_issue_state?(issue.state) ->
        handle_auto_review_state(state, issue)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        force_kill_ref = Map.get(running_entry, :force_kill_timer_ref)
        if is_reference(force_kill_ref), do: Process.cancel_timer(force_kill_ref)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host)
        end

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().agent.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          state_acc = maybe_update_workspace_activity(state_acc, issue_id, running_entry)
          running_entry = Map.get(state_acc.running, issue_id)
          state_acc = maybe_update_process_alive(state_acc, issue_id, running_entry)
          running_entry = Map.get(state_acc.running, issue_id)
          state_acc = maybe_poll_acpx_session_stream(state_acc, issue_id, running_entry)
          running_entry = Map.get(state_acc.running, issue_id)
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp maybe_update_workspace_activity(state, issue_id, running_entry) do
    workspace_path = Map.get(running_entry, :workspace_path)

    if is_binary(workspace_path) and workspace_path != "" do
      now = DateTime.utc_now()
      scan_interval_ms = Config.settings!().agent.workspace_activity_scan_interval_ms
      last_scan_at = Map.get(running_entry, :last_workspace_activity_scan_at)

      if last_scan_at == nil or DateTime.diff(now, last_scan_at, :millisecond) >= scan_interval_ms do
        case WorkspaceActivity.scan_workspace_activity(workspace_path, Map.get(running_entry, :last_workspace_activity_at)) do
          {:active, mtime} ->
            updated =
              running_entry
              |> Map.put(:last_workspace_activity_at, mtime)
              |> Map.put(:last_workspace_activity_scan_at, now)
              |> Map.put(:progress_source, update_progress_source(Map.put(running_entry, :last_workspace_activity_at, mtime)))

            %{state | running: Map.put(state.running, issue_id, updated)}

          {:stale, nil} ->
            updated = Map.put(running_entry, :last_workspace_activity_scan_at, now)
            %{state | running: Map.put(state.running, issue_id, updated)}
        end
      else
        state
      end
    else
      state
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    case stall_status(running_entry, now, timeout_ms) do
      :not_stalled ->
        state

      :maybe_stalled ->
        Logger.info("Agent process alive but no raw events or workspace activity for issue_id=#{issue_id}; extending observation")
        state

      :stalled ->
        identifier = Map.get(running_entry, :identifier, issue_id)
        session_id = running_entry_session_id(running_entry)

        if Map.get(running_entry, :status) == :terminating do
          Logger.warning("Issue already terminating: issue_id=#{issue_id} issue_identifier=#{identifier}; waiting for shutdown")
          state
        else
          Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id}; terminating attempt")

          pid = Map.get(running_entry, :pid)

          if is_pid(pid) do
            terminate_task(pid)
          end

          terminating_entry =
            running_entry
            |> Map.put(:status, :terminating)
            |> Map.put(:force_kill_timer_ref, Process.send_after(self(), {:force_kill_attempt, issue_id}, @attempt_shutdown_timeout_ms))

          %{state | running: Map.put(state.running, issue_id, terminating_entry)}
        end
    end
  end

  defp maybe_update_process_alive(state, issue_id, running_entry) do
    pid = Map.get(running_entry, :pid)

    if is_pid(pid) and Process.alive?(pid) do
      now = DateTime.utc_now()
      with_seen = Map.put(running_entry, :last_process_seen_at, now)
      updated = Map.put(with_seen, :progress_source, update_progress_source(with_seen))
      %{state | running: Map.put(state.running, issue_id, updated)}
    else
      state
    end
  end

  defp maybe_poll_acpx_session_stream(state, issue_id, running_entry) do
    acpx_record_id = Map.get(running_entry, :acpx_record_id)

    if is_binary(acpx_record_id) do
      current_source = Map.get(running_entry, :progress_source, "none")
      needs_poll = current_source in ["none", "process_alive", "stalled_no_events", "workspace_activity"]

      if needs_poll do
        stream_bytes_read = Map.get(running_entry, :stream_bytes_read, 0)

        progress = SymphonyElixir.AgentRunner.AcpxSessionStream.read_progress(
          acpx_record_id,
          bytes_offset: stream_bytes_read,
          session_root: state.acpx_session_root
        )

        if progress.latest_event_at != nil do
          updated =
            running_entry
            |> Map.put(:last_raw_event_at, progress.latest_event_at)
            |> Map.put(:last_raw_preview, progress.latest_preview || Map.get(running_entry, :last_raw_preview))
            |> Map.put(:last_agent_message, progress.latest_message || Map.get(running_entry, :last_agent_message))
            |> Map.put(:progress_source, "acpx_session_stream")
            |> Map.put(:stream_bytes_read, progress.bytes_read)
            |> update_token_usage_from_stream(progress)
            |> then(fn entry ->
              if progress.parser_errors > 0 do
                Map.update!(entry, :consecutive_parser_errors, &(&1 + progress.parser_errors))
              else
                Map.put(entry, :consecutive_parser_errors, 0)
              end
            end)

          %{state | running: Map.put(state.running, issue_id, updated)}
        else
          if progress.stream_exists do
            %{state | running: Map.put(state.running, issue_id, Map.put(running_entry, :stream_bytes_read, progress.bytes_read))}
          else
            state
          end
        end
      else
        state
      end
    else
      state
    end
  end

  defp update_token_usage_from_stream(running_entry, progress) do
    usage = progress.token_usage

    if usage.total_tokens > 0 do
      running_entry
      |> Map.put(:agent_input_tokens, max(Map.get(running_entry, :agent_input_tokens, 0), usage.input_tokens))
      |> Map.put(:agent_output_tokens, max(Map.get(running_entry, :agent_output_tokens, 0), usage.output_tokens))
      |> Map.put(:agent_total_tokens, max(Map.get(running_entry, :agent_total_tokens, 0), usage.total_tokens))
      |> Map.put(:agent_cached_read_tokens, max(Map.get(running_entry, :agent_cached_read_tokens, 0), usage.cached_read_tokens))
      |> Map.put(:agent_cached_write_tokens, max(Map.get(running_entry, :agent_cached_write_tokens, 0), usage.cached_write_tokens))
    else
      running_entry
    end
  end

  defp stall_status(running_entry, now, timeout_ms) do
    raw_event_at = Map.get(running_entry, :last_raw_event_at)
    workspace_activity_at = Map.get(running_entry, :last_workspace_activity_at)
    _process_seen_at = Map.get(running_entry, :last_process_seen_at)
    started_at = Map.get(running_entry, :started_at)
    started_elapsed = elapsed_since(started_at, now)

    cond do
      fresh_within?(raw_event_at, now, timeout_ms) ->
        :not_stalled

      fresh_within?(workspace_activity_at, now, timeout_ms) ->
        :not_stalled

      process_alive_with_recent_seen?(running_entry, now, timeout_ms) and started_elapsed <= timeout_ms * 3 ->
        :maybe_stalled

      started_elapsed > timeout_ms ->
        :stalled

      true ->
        :not_stalled
    end
  end

  defp fresh_within?(nil, _now, _timeout_ms), do: false

  defp fresh_within?(timestamp, now, timeout_ms) when is_struct(timestamp, DateTime) do
    DateTime.diff(now, timestamp, :millisecond) <= timeout_ms
  end

  defp fresh_within?(_, _, _), do: false

  defp process_alive_with_recent_seen?(running_entry, now, timeout_ms) do
    pid = Map.get(running_entry, :pid)
    process_seen_at = Map.get(running_entry, :last_process_seen_at)

    is_pid(pid) and Process.alive?(pid) and
      is_struct(process_seen_at, DateTime) and
      DateTime.diff(now, process_seen_at, :millisecond) <= timeout_ms * 2
  end

  defp elapsed_since(nil, _now), do: 0

  defp elapsed_since(timestamp, now) when is_struct(timestamp, DateTime) do
    DateTime.diff(now, timestamp, :millisecond)
  end

  defp elapsed_since(_, _), do: 0

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(issues, state, orchestrator_pid) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      dispatchable = should_dispatch_issue?(issue, state_acc, active_states, terminal_states)
      if dispatchable do
        dispatch_issue(state_acc, issue, nil, nil, orchestrator_pid)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed, blocked: blocked} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !auto_review_issue_state?(issue.state) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      required_label_passed?(issue) and
      !Map.has_key?(blocked, issue.id) and
      !MapSet.member?(claimed, issue.id) and
      !issue_has_active_or_terminating_attempt?(running, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp required_label_passed?(%Issue{labels: labels}) do
    case Config.settings!().tracker.required_label do
      nil -> true
      required_label -> is_list(labels) and Enum.any?(labels, &String.downcase(&1) == String.downcase(required_label))
    end
  end

  defp maybe_apply_dispatch_label(%Issue{id: issue_id}) do
    case Config.settings!().tracker.dispatch_label do
      nil -> :ok
      dispatch_label ->
        case Tracker.add_label(issue_id, dispatch_label) do
          :ok -> :ok
          {:error, reason} ->
            Logger.warning("Failed to add dispatch label to #{issue_id}: #{inspect(reason)}")
            :ok
        end
    end
  end

  defp maybe_post_dispatch_comment(%Issue{id: issue_id}) do
    case Config.settings!().tracker.dispatch_label do
      nil -> :ok
      _dispatch_label ->
        case Tracker.create_comment(issue_id, "🤖 Symphony has started working on this issue.") do
          :ok -> :ok
          {:error, reason} ->
            Logger.warning("Failed to post dispatch comment to #{issue_id}: #{inspect(reason)}")
            :ok
        end
    end
  end

  defp issue_has_active_or_terminating_attempt?(running, issue_id) do
    case Map.get(running, issue_id) do
      nil -> false
      %{status: status} when status in [:terminating] -> true
      _ -> true
    end
  end

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, orchestrator_pid) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host, orchestrator_pid)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, orchestrator_pid) do
    recipient = orchestrator_pid || self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host) do
    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(issue, recipient, attempt: attempt, worker_host: worker_host)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        maybe_apply_dispatch_label(issue)
        maybe_post_dispatch_comment(issue)

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: nil,
            status: :running,
            session_name: nil,
            session_id: nil,
            attempt_id: issue.id,
            phase: "starting",
            last_agent_message: nil,
            last_agent_timestamp: nil,
            last_agent_event: nil,
            last_raw_event_at: nil,
            last_raw_preview: nil,
            agent_session_pid: nil,
            agent_input_tokens: 0,
            agent_output_tokens: 0,
            agent_total_tokens: 0,
            agent_cached_read_tokens: 0,
            agent_cached_write_tokens: 0,
            agent_last_reported_input_tokens: 0,
            agent_last_reported_output_tokens: 0,
            agent_last_reported_total_tokens: 0,
            agent_last_reported_cached_read_tokens: 0,
            agent_last_reported_cached_write_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            started_at: DateTime.utc_now(),
            last_workspace_activity_at: nil,
            last_workspace_activity_scan_at: nil,
            last_process_seen_at: nil,
            progress_source: "none",
            acpx_record_id: nil,
            stream_bytes_read: 0
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    completed =
      state.completed
      |> MapSet.put(issue_id)
      |> maybe_trim_completed()

    %{
      state
      | completed: completed,
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp maybe_trim_completed(completed) do
    if MapSet.size(completed) > @max_completed_set_size do
      completed
      |> MapSet.to_list()
      |> Enum.take(-div(@max_completed_set_size, 2))
      |> MapSet.new()
    else
      completed
    end
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      Map.has_key?(state.blocked, issue_id) ->
        Logger.debug("Issue is blocked, skipping retry: issue_id=#{issue_id} issue_identifier=#{issue.identifier}")
        {:noreply, release_issue_claim(state, issue_id)}

      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    workspace_path = metadata[:workspace_path]
    worker_host = metadata[:worker_host]

    cond do
      workspace_path != nil ->
        case Workspace.dirty_files(workspace_path, worker_host) do
          {:dirty, dirty_files} ->
            blocked_state =
              block_issue(
                state,
                issue.id,
                %{
                  identifier: issue.identifier,
                  workspace_path: workspace_path,
                  reason: "workspace_dirty_on_retry",
                  dirty_files: dirty_files,
                  last_error: metadata[:error]
                },
                DateTime.utc_now()
              )

            {:noreply, blocked_state}

          {:unknown, _} ->
            blocked_state =
              block_issue(
                state,
                issue.id,
                %{
                  identifier: issue.identifier,
                  workspace_path: workspace_path,
                  reason: "workspace_unknown_after_retry",
                  dirty_files: [],
                  last_error: metadata[:error]
                },
                DateTime.utc_now()
              )

            {:noreply, blocked_state}

          {:clean, _} ->
            maybe_dispatch_or_retry(state, issue, attempt, metadata)
        end

      true ->
        maybe_dispatch_or_retry(state, issue, attempt, metadata)
    end
  end

  defp maybe_dispatch_or_retry(state, issue, attempt, metadata) do
    worker_host = metadata[:worker_host]

    if retry_candidate_issue?(issue, terminal_state_set()) and
       dispatch_slots_available?(issue, state) and
       worker_slots_available?(state, worker_host) do
      {:noreply, dispatch_issue(state, issue, attempt, worker_host, nil)}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  @spec block_issue(State.t(), String.t(), map(), DateTime.t()) :: State.t()
  def block_issue(%State{} = state, issue_id, metadata, blocked_at) when is_binary(issue_id) and is_map(metadata) do
    %{
      identifier: identifier,
      workspace_path: workspace_path,
      reason: reason,
      dirty_files: dirty_files,
      last_error: last_error
    } = metadata

    Logger.info(
      "Issue blocked: issue_id=#{issue_id} issue_identifier=#{identifier} reason=#{reason} workspace_path=#{workspace_path} dirty_files=#{inspect(dirty_files)}"
    )

    state
    |> Map.put(:blocked, Map.put(state.blocked, issue_id, %{
      identifier: identifier,
      workspace_path: workspace_path,
      reason: reason,
      dirty_files: dirty_files,
      last_error: last_error,
      blocked_at: blocked_at
    }))
    |> release_issue_claim(issue_id)
    |> Map.put(:retry_attempts, Map.delete(state.retry_attempts, issue_id))
  end

  @spec unblock_issue(State.t(), String.t()) :: State.t()
  def unblock_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    %{state | blocked: Map.delete(state.blocked, issue_id)}
  end

  defp expire_blocked_entries(%State{blocked: blocked} = state) do
    now = DateTime.utc_now()

    expired_ids =
      blocked
      |> Enum.filter(fn {_issue_id, entry} ->
        case Map.get(entry, :blocked_at) do
          %DateTime{} = blocked_at ->
            DateTime.diff(now, blocked_at, :second) > @blocked_ttl_seconds

          _ ->
            false
        end
      end)
      |> Enum.map(fn {issue_id, _entry} -> issue_id end)

    if expired_ids == [] do
      state
    else
      Logger.info("Expiring #{length(expired_ids)} blocked entries past TTL")
      %{state | blocked: Map.drop(blocked, expired_ids)}
    end
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      continuation_retry_delay_ms()
    else
      failure_retry_delay(attempt)
    end
  end

  defp continuation_retry_delay_ms do
    case Config.settings!().agent.continuation_retry_delay_ms do
      delay when is_integer(delay) and delay > 0 -> delay
      _ -> @default_continuation_retry_delay_ms
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp check_workspace_dirty(nil, _worker_host), do: {:unknown, []}
  defp check_workspace_dirty(workspace_path, worker_host) when is_binary(workspace_path) do
    Workspace.dirty_files(workspace_path, worker_host)
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp handle_review_down(ref, reason, reviews, state) do
    review_entry =
      Enum.find_value(reviews, fn {issue_id, entry} ->
        if entry[:ref] == ref, do: {issue_id, entry}
      end)

    case review_entry do
      {issue_id, _entry} ->
        Logger.warning("Review task for issue_id=#{issue_id} crashed: #{inspect(reason)}")
        {:noreply, %{state | reviews: Map.delete(reviews, issue_id)}}

      nil ->
        {:noreply, state}
    end
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:run_reconcile, _from, state) do
    new_state = reconcile_stalled_running_issues(state)
    new_state = schedule_tick(new_state, new_state.poll_interval_ms)
    new_state = %{new_state | poll_check_in_progress: false}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          attempt_status: Map.get(metadata, :status, :running),
          session_id: metadata.session_id,
          session_name: Map.get(metadata, :session_name),
          attempt_id: Map.get(metadata, :attempt_id),
          phase: Map.get(metadata, :phase),
          last_raw_event_at: Map.get(metadata, :last_raw_event_at),
          last_raw_preview: Map.get(metadata, :last_raw_preview),
          agent_session_pid: Map.get(metadata, :agent_session_pid),
          agent_input_tokens: metadata.agent_input_tokens,
          agent_output_tokens: metadata.agent_output_tokens,
          agent_total_tokens: metadata.agent_total_tokens,
          agent_cached_read_tokens: Map.get(metadata, :agent_cached_read_tokens, 0),
          agent_cached_write_tokens: Map.get(metadata, :agent_cached_write_tokens, 0),
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_agent_timestamp: metadata.last_agent_timestamp,
          last_agent_message: metadata.last_agent_message,
          last_agent_event: metadata.last_agent_event,
          progress_source: Map.get(metadata, :progress_source, "none"),
          last_workspace_activity_at: Map.get(metadata, :last_workspace_activity_at),
          last_workspace_activity_scan_at: Map.get(metadata, :last_workspace_activity_scan_at),
          last_process_seen_at: Map.get(metadata, :last_process_seen_at),
          acpx_record_id: Map.get(metadata, :acpx_record_id),
          pid: Map.get(metadata, :pid),
          consecutive_parser_errors: Map.get(metadata, :consecutive_parser_errors, 0),
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    blocked =
      state.blocked
      |> Enum.map(fn {issue_id, entry} ->
        %{
          issue_id: issue_id,
          identifier: entry.identifier,
          workspace_path: entry.workspace_path,
          reason: entry.reason,
          dirty_files: entry.dirty_files,
          last_error: entry.last_error,
          blocked_at: entry.blocked_at
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       blocked: blocked,
       agent_totals: state.agent_totals,
       rate_limits: Map.get(state, :agent_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp integrate_agent_update(running_entry, %{event: :acpx_record_id, acpx_record_id: acpx_record_id}) do
    {Map.put(running_entry, :acpx_record_id, acpx_record_id), %{}}
  end

  defp integrate_agent_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    agent_input_tokens = Map.get(running_entry, :agent_input_tokens, 0)
    agent_output_tokens = Map.get(running_entry, :agent_output_tokens, 0)
    agent_total_tokens = Map.get(running_entry, :agent_total_tokens, 0)
    agent_cached_read_tokens = Map.get(running_entry, :agent_cached_read_tokens, 0)
    agent_cached_write_tokens = Map.get(running_entry, :agent_cached_write_tokens, 0)
    agent_session_pid = Map.get(running_entry, :agent_session_pid)
    last_reported_input = Map.get(running_entry, :agent_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :agent_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :agent_last_reported_total_tokens, 0)
    last_reported_cached_read = Map.get(running_entry, :agent_last_reported_cached_read_tokens, 0)
    last_reported_cached_write = Map.get(running_entry, :agent_last_reported_cached_write_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)
    session_name = Map.get(update, :session_name) || Map.get(running_entry, :session_name)

    {phase, raw_preview} =
      case update do
        %{phase: p} when is_binary(p) -> {p, Map.get(update, :raw_preview)}
        _ -> {Map.get(running_entry, :phase), nil}
      end

    consecutive_parser_errors =
      case event do
        :parser_error -> (Map.get(running_entry, :consecutive_parser_errors, 0) + 1)
        _ -> 0
      end

    merged =
      Map.merge(running_entry, %{
        last_agent_timestamp: timestamp,
        last_agent_message: summarize_agent_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        session_name: session_name,
        phase: phase,
        last_agent_event: event,
        last_raw_event_at: Map.get(update, :raw_event_at) || Map.get(running_entry, :last_raw_event_at),
        last_raw_preview: raw_preview || Map.get(running_entry, :last_raw_preview),
        agent_session_pid: agent_session_pid_for_update(agent_session_pid, update),
        agent_input_tokens: agent_input_tokens + token_delta.input_tokens,
        agent_output_tokens: agent_output_tokens + token_delta.output_tokens,
        agent_total_tokens: agent_total_tokens + token_delta.total_tokens,
        agent_cached_read_tokens: agent_cached_read_tokens + Map.get(token_delta, :cached_read_tokens, 0),
        agent_cached_write_tokens: agent_cached_write_tokens + Map.get(token_delta, :cached_write_tokens, 0),
        agent_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        agent_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        agent_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        agent_last_reported_cached_read_tokens: max(last_reported_cached_read, Map.get(token_delta, :cached_read_reported, 0)),
        agent_last_reported_cached_write_tokens: max(last_reported_cached_write, Map.get(token_delta, :cached_write_reported, 0)),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update),
        consecutive_parser_errors: consecutive_parser_errors,
        progress_source: update_progress_source(Map.merge(running_entry, %{
          last_raw_event_at: Map.get(update, :raw_event_at) || Map.get(running_entry, :last_raw_event_at),
          last_workspace_activity_at: Map.get(running_entry, :last_workspace_activity_at),
          last_process_seen_at: Map.get(running_entry, :last_process_seen_at),
          consecutive_parser_errors: consecutive_parser_errors
        }))
      })

    {merged, token_delta}
  end

  @max_consecutive_parser_errors 3
  @stalled_no_events_grace_seconds 60

  defp update_progress_source(running_entry) do
    cond do
      Map.get(running_entry, :last_raw_event_at) != nil ->
        case Map.get(running_entry, :consecutive_parser_errors, 0) > @max_consecutive_parser_errors do
          true -> "parser_error"
          false ->
            case Map.get(running_entry, :progress_source) do
              "acpx_session_stream" -> "acpx_session_stream"
              _ -> "raw_event"
            end
        end
      Map.get(running_entry, :last_workspace_activity_at) != nil -> "workspace_activity"
      Map.get(running_entry, :last_process_seen_at) != nil -> "process_alive"
      true -> "none"
    end
  end

  @doc """
  Reconcile progress source for running entries that have been alive for a
  bounded grace period but never produced a raw event. Used by the status
  reconciliation loop to escalate ambiguous states.
  """
  @spec reconcile_progress_source(map()) :: map()
  def reconcile_progress_source(entry) do
    current_source = Map.get(entry, :progress_source, "none")
    last_raw = Map.get(entry, :last_raw_event_at)

    updated_source =
      cond do
        current_source in ["parser_error", "stalled_no_events", "acpx_session_stream"] ->
          current_source

        last_raw != nil ->
          if Map.get(entry, :consecutive_parser_errors, 0) > @max_consecutive_parser_errors do
            "parser_error"
          else
            "raw_event"
          end

        current_source == "process_alive" ->
          if stalled_past_grace?(entry) do
            "stalled_no_events"
          else
            current_source
          end

        true ->
          current_source
      end

    if updated_source != current_source do
      Logger.info("Progress source escalated: #{current_source} -> #{updated_source} for issue_id=#{Map.get(entry, :issue_id)}")
      Map.put(entry, :progress_source, updated_source)
    else
      entry
    end
  end

  defp stalled_past_grace?(entry) do
    reference_time = Map.get(entry, :started_at) || Map.get(entry, :last_process_seen_at)
    last_raw = Map.get(entry, :last_raw_event_at)

    reference_time != nil and last_raw == nil and
      DateTime.diff(DateTime.utc_now(), reference_time, :second) > @stalled_no_events_grace_seconds
  end

  defp maybe_block_on_boundary_violation(state, issue_id, running_entry, update) do
    event = Map.get(update, :event)

    if event in [:agent_message, :tool_call, :tool_result] do
      text = extract_event_text(update)

      case detect_boundary_violation(text, state) do
        {:violation, forbidden_path} ->
          Logger.warning("Workspace boundary violation detected for issue_id=#{issue_id}: agent referenced forbidden path #{forbidden_path}")

          identifier = Map.get(running_entry, :identifier)
          workspace_path = Map.get(running_entry, :workspace_path)
          agent_pid = Map.get(running_entry, :pid)
          ref = Map.get(running_entry, :ref)

          if is_pid(agent_pid) do
            terminate_task(agent_pid)
          end

          if is_reference(ref) do
            Process.demonitor(ref, [:flush])
          end

          blocked_entry = %{
            identifier: identifier,
            workspace_path: workspace_path,
            reason: "workspace_boundary_violation",
            dirty_files: [],
            last_error: "agent attempted to access forbidden path",
            blocked_at: DateTime.utc_now()
          }

          running = Map.delete(state.running, issue_id)
          %{state | running: running, blocked: Map.put(state.blocked, issue_id, blocked_entry)}

        :ok ->
          state
      end
    else
      state
    end
  end

  defp extract_event_text(%{payload: payload}) when is_map(payload) do
    content = payload["content"] || payload["update"] || ""
    case content do
      c when is_map(c) -> c["text"] || inspect(c)
      c when is_binary(c) -> c
      _ -> ""
    end
  end

  defp extract_event_text(%{payload: payload}) when is_binary(payload), do: payload
  defp extract_event_text(_), do: ""

  defp detect_boundary_violation(text, _state) when is_binary(text) do
    config = Config.settings!()
    source_checkout_path = config.workspace.source_checkout_path

    if source_checkout_path != nil and source_checkout_path != "" do
      forbidden = normalize_path_for_comparison(source_checkout_path)

      cd_patterns = [
        ~r/cd\s+#{Regex.escape(source_checkout_path)}/i,
        ~r/Set-Location\s+#{Regex.escape(source_checkout_path)}/i,
        ~r/Push-Location\s+#{Regex.escape(source_checkout_path)}/i,
        ~r/cd\s+["']#{Regex.escape(source_checkout_path)}["']/i
      ]

      text_lower = String.downcase(text)
      forbidden_lower = String.downcase(forbidden)

      cond do
        Enum.any?(cd_patterns, &Regex.match?(&1, text)) ->
          {:violation, source_checkout_path}

        String.contains?(text_lower, forbidden_lower) and
          String.contains?(text_lower, "cd ") ->
          {:violation, source_checkout_path}

        true ->
          :ok
      end
    else
      :ok
    end
  end

  defp detect_boundary_violation(_text, _state), do: :ok

  defp normalize_path_for_comparison(path) when is_binary(path) do
    path
    |> String.replace("\\", "/")
    |> String.trim_trailing("/")
  end

  defp agent_session_pid_for_update(_existing, %{agent_session_pid: pid})
       when is_binary(pid),
       do: pid

  defp agent_session_pid_for_update(_existing, %{agent_session_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp agent_session_pid_for_update(_existing, %{agent_session_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp agent_session_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :turn_completed,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count + 1
    else
      existing_count
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_agent_update(update) do
    %{
      event: update[:event],
      message: summarize_payload(update[:payload]) || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp summarize_payload(%{"content" => %{"text" => text}}) when is_binary(text) do
    String.slice(text, 0, 200)
  end

  defp summarize_payload(%{"content" => content}) when is_binary(content) do
    String.slice(content, 0, 200)
  end

  defp summarize_payload(payload) when is_map(payload) do
    case Jason.encode(payload) do
      {:ok, json} -> String.slice(json, 0, 200)
      _ -> nil
    end
  end

  defp summarize_payload(_), do: nil

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    agent_totals =
      apply_token_delta(
        state.agent_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | agent_totals: agent_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_agent_token_delta(
         %{agent_totals: agent_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | agent_totals: apply_token_delta(agent_totals, token_delta)}
  end

  defp apply_agent_token_delta(state, _token_delta), do: state

  defp apply_agent_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | agent_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_agent_rate_limits(state, _update), do: state

defp apply_token_delta(agent_totals, token_delta) do
    input_tokens = Map.get(agent_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(agent_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(agent_totals, :total_tokens, 0) + token_delta.total_tokens
    cached_read_tokens = Map.get(agent_totals, :cached_read_tokens, 0) + Map.get(token_delta, :cached_read_tokens, 0)
    cached_write_tokens = Map.get(agent_totals, :cached_write_tokens, 0) + Map.get(token_delta, :cached_write_tokens, 0)
    seconds_running =
      Map.get(agent_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)


    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      cached_read_tokens: max(0, cached_read_tokens),
      cached_write_tokens: max(0, cached_write_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    input_delta = compute_token_delta(running_entry, :input, usage, :agent_last_reported_input_tokens)
    output_delta = compute_token_delta(running_entry, :output, usage, :agent_last_reported_output_tokens)
    total_delta = compute_token_delta(running_entry, :total, usage, :agent_last_reported_total_tokens)
    cached_read_delta = compute_token_delta(running_entry, :cached_read, usage, :agent_last_reported_cached_read_tokens)
    cached_write_delta = compute_token_delta(running_entry, :cached_write, usage, :agent_last_reported_cached_write_tokens)

    %{
      input_tokens: input_delta.delta,
      output_tokens: output_delta.delta,
      total_tokens: total_delta.delta,
      cached_read_tokens: cached_read_delta.delta,
      cached_write_tokens: cached_write_delta.delta,
      input_reported: input_delta.reported,
      output_reported: output_delta.reported,
      total_reported: total_delta.reported,
      cached_read_reported: cached_read_delta.reported,
      cached_write_reported: cached_write_delta.reported
    }
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp get_token_usage(usage, :cached_read),
    do:
      payload_get(usage, [
        "cached_read_tokens",
        :cached_read_tokens,
        "cachedReadTokens",
        :cachedReadTokens
      ])

  defp get_token_usage(usage, :cached_write),
    do:
      payload_get(usage, [
        "cached_write_tokens",
        :cached_write_tokens,
        "cachedWriteTokens",
        :cachedWriteTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil

  defp deterministic_infra_failure?(reason) do
    infra_failure_reason(reason) != nil
  end

  defp infra_failure_block_reason(reason) do
    infra_failure_reason(reason) || "unknown_infra_failure"
  end

  defp infra_failure_reason({:session_ensure_failed, {:acpx_record_id_missing, _}}) do
    "acpx_session_ensure_missing_record_id"
  end

  defp infra_failure_reason({:session_ensure_failed, {:acpx_cli_resolution_failed, _}}) do
    "acpx_cli_resolution_failed"
  end

  defp infra_failure_reason({:workspace_hook_failed, _, _, _}) do
    "workspace_hook_failure"
  end

  defp infra_failure_reason(_), do: nil

  defp auto_review_issue_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == "auto review"
  end

  defp auto_review_issue_state?(_state_name), do: false

  defp handle_auto_review_state(%State{reviews: reviews, blocked: blocked} = state, %Issue{} = issue) do
    config = Config.settings!()

    cond do
      Map.has_key?(blocked, issue.id) ->
        state

      not config.review.enabled ->
        Logger.warning("Issue in Auto Review but review is disabled: #{issue_context(issue)}; blocking to prevent silent stuck")

        block_issue(state, issue.id, %{
          identifier: issue.identifier,
          workspace_path: nil,
          reason: "auto_review_disabled",
          dirty_files: [],
          last_error: "issue in Auto Review state but review.enabled=false"
        }, DateTime.utc_now())

      Map.has_key?(reviews, issue.id) ->
        state

      true ->
        workspace_path = get_workspace_path_for_review(state, issue)

        if is_nil(workspace_path) do
          Logger.warning("Cannot start auto review: no workspace path for #{issue_context(issue)}")
          state
        else
          Logger.info("Starting auto review for #{issue_context(issue)} workspace=#{workspace_path}")

          me = self()

          {:ok, review_pid} =
            Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
              review_result =
                try do
                  Runner.run(issue, workspace_path, config)
                rescue
                  e -> {:error, {:runner_exception, e}}
                end

              send(me, {:review_completed, issue, review_result})
            end)

          review_ref = Process.monitor(review_pid)

          %{state | reviews: Map.put(state.reviews, issue.id, %{started_at: DateTime.utc_now(), pid: review_pid, ref: review_ref})}
        end
    end
  end

  defp get_workspace_path_for_review(%State{running: running, retry_attempts: retry_attempts}, %Issue{id: issue_id, identifier: identifier}) do
    case Map.get(running, issue_id) do
      %{workspace_path: path} when is_binary(path) and path != "" ->
        path

      _ ->
        case Map.get(retry_attempts, issue_id) do
          %{workspace_path: path} when is_binary(path) and path != "" ->
            path

          _ ->
            Workspace.path_for_identifier(identifier)
        end
    end
  end

  defp handle_review_result(%Issue{} = issue, {:ok, results}) do
    report = Reporter.build_report(results)
    Logger.info("Auto review completed for #{issue_context(issue)}")

    case Tracker.create_comment(issue.id, report) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to post review comment for #{issue_context(issue)}: #{inspect(reason)}")
    end

    case Tracker.update_issue_state(issue.id, "Human Review") do
      :ok -> Logger.info("Transitioned #{issue_context(issue)} to Human Review")
      {:error, reason} -> Logger.warning("Failed to transition #{issue_context(issue)} to Human Review: #{inspect(reason)}")
    end
  end

  defp handle_review_result(%Issue{} = issue, {:error, reason}) do
    Logger.warning("Auto review failed for #{issue_context(issue)}: #{inspect(reason)}")

    failure_message = "## 自动评审失败\n\n评审执行出错: `#{inspect(reason)}`\n\n请手动检查代码。"

    case Tracker.create_comment(issue.id, failure_message) do
      :ok -> :ok
      {:error, comment_reason} -> Logger.warning("Failed to post review failure comment for #{issue_context(issue)}: #{inspect(comment_reason)}")
    end

    case Tracker.update_issue_state(issue.id, "Human Review") do
      :ok -> Logger.info("Transitioned #{issue_context(issue)} to Human Review after review failure")
      {:error, state_reason} -> Logger.warning("Failed to transition #{issue_context(issue)} to Human Review: #{inspect(state_reason)}")
    end
  end
end

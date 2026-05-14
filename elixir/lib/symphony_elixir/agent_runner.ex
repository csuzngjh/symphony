defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with an agent (ACPX).
  """

  require Logger
  alias SymphonyElixir.AgentRunner.AcpxSession
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_agent_turns(workspace, issue, update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp message_handler(recipient, issue) do
    fn message ->
      send_agent_update(recipient, issue, message)
    end
  end

  defp send_agent_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:agent_worker_update, issue_id, message})
    :ok
  end

  defp send_agent_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_agent_turns(workspace, issue, update_recipient, opts, _worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    agent = agent_name_from_config()
    session_name = "issue-#{issue.id}"

    send_phase_update(update_recipient, issue, "starting_session", session_name)

    case AcpxSession.start_link(
            agent: agent,
            cwd: workspace,
            recipient: update_recipient,
            issue_id: issue.id,
            acpx_options: acpx_options_from_config()
          ) do
      {:ok, session_pid} ->
        try do
          send_phase_update(update_recipient, issue, "ensuring_session", session_name)

          case AcpxSession.sessions_ensure(session_pid, session_name, workspace) do
            {:ok, _session_id} ->
              send_phase_update(update_recipient, issue, "session_ready", session_name)

              try do
                do_run_acpx_turns(session_pid, workspace, issue, update_recipient, opts, issue_state_fetcher, 1, max_turns)
              after
                AcpxSession.sessions_close(session_pid)
              end

            {:error, reason} ->
              Logger.warning("Failed to create acpx session, falling back to exec mode: #{inspect(reason)}")
              send_phase_update(update_recipient, issue, "exec_fallback", session_name)
              do_run_acpx_turns_exec(session_pid, workspace, issue, update_recipient, opts, issue_state_fetcher, 1, max_turns)
          end
        after
          GenServer.stop(session_pid, :normal)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_phase_update(nil, _issue, _phase, _session_name), do: :ok

  defp send_phase_update(recipient, %Issue{id: issue_id}, phase, session_name)
       when is_binary(issue_id) and is_pid(recipient) do
    send(
      recipient,
      {:agent_worker_update, issue_id,
       %{
         event: :phase_update,
         phase: phase,
         session_name: session_name,
         timestamp: DateTime.utc_now()
       }}
    )

    :ok
  end

  defp send_phase_update(_recipient, _issue, _phase, _session_name), do: :ok

  defp do_run_acpx_turns(session_pid, workspace, issue, update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    do_run_turns(:prompt, session_pid, workspace, issue, update_recipient, opts, issue_state_fetcher, turn_number, max_turns)
  end

  defp do_run_acpx_turns_exec(session_pid, workspace, issue, update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    do_run_turns(:exec, session_pid, workspace, issue, update_recipient, opts, issue_state_fetcher, turn_number, max_turns)
  end

  defp do_run_turns(mode, session_pid, workspace, issue, update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)
    send_fn = if mode == :prompt, do: &AcpxSession.prompt/2, else: &AcpxSession.exec/2

    send_phase_update(update_recipient, issue, "prompt_sent_turn_#{turn_number}", "issue-#{issue.id}")

    case send_fn.(session_pid, prompt) do
      {:ok, _result} ->
        next_turn_fn = fn refreshed_issue, next_turn ->
          do_run_turns(mode, session_pid, workspace, refreshed_issue, update_recipient, opts, issue_state_fetcher, next_turn, max_turns)
        end

        handle_turn_completion(issue, workspace, session_pid, update_recipient, opts, issue_state_fetcher, turn_number, max_turns, next_turn_fn)

      {:error, reason} ->
        Logger.warning("Agent #{mode} failed for #{issue_context(issue)} turn=#{turn_number}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp agent_name_from_config do
    case Config.settings!().agent.agent_name do
      agent when is_binary(agent) and agent != "" -> agent
      _ -> "claude"
    end
  end

  defp acpx_options_from_config do
    settings = Config.settings!()

    max_turns_acpx =
      case Config.settings!().agent.max_turns do
        n when is_integer(n) and n > 0 -> n
        _ -> nil
      end

    %{
      model: Config.settings!().agent.model,
      allowed_tools: Config.settings!().agent.allowed_tools,
      prompt_retries: Config.settings!().agent.prompt_retries,
      timeout: timeout_seconds(Config.settings!().agent.turn_timeout_ms),
      ttl: 300,
      suppress_reads: true,
      no_terminal: true
    }
    |> then(fn opts ->
      if max_turns_acpx, do: Map.put(opts, :max_turns, max_turns_acpx), else: opts
    end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp timeout_seconds(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    max(1, div(timeout_ms + 999, 1000))
  end

  defp timeout_seconds(_), do: nil

  defp handle_turn_completion(issue, workspace, _session_pid, _update_recipient, _opts, issue_state_fetcher, turn_number, max_turns, next_turn_fn) do
    Logger.info("Completed agent turn for #{issue_context(issue)} workspace=#{workspace} turn=#{turn_number}/#{max_turns_label(max_turns)}")

    case continue_with_issue?(issue, issue_state_fetcher) do
      {:continue, refreshed_issue} when max_turns == -1 or turn_number < max_turns ->
        Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns_label(max_turns)}")

        next_turn_fn.(refreshed_issue, turn_number + 1)

      {:continue, refreshed_issue} ->
        Logger.info("Reached max turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")
        :ok

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous agent turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns_label(max_turns)} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp max_turns_label(-1), do: "unlimited"
  defp max_turns_label(n), do: to_string(n)

  @doc false
  def __testing__ do
    %{
      selected_worker_host: &selected_worker_host/2,
      continue_with_issue: &continue_with_issue?/2,
      active_issue_state: &active_issue_state?/1,
      acpx_options_from_config: &acpx_options_from_config/0,
      timeout_seconds: &timeout_seconds/1,
      agent_name_from_config: &agent_name_from_config/0,
      build_turn_prompt: &build_turn_prompt/4,
      send_agent_update: &send_agent_update/3,
      send_worker_runtime_info: &send_worker_runtime_info/4,
      normalize_issue_state: &normalize_issue_state/1,
      max_turns_label: &max_turns_label/1
    }
  end
end

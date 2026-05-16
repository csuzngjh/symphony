defmodule SymphonyElixir.AgentRunner.AcpxSession do
  @moduledoc """
  GenServer that manages acpx session lifecycle for persistent multi-turn conversations.

  Uses AcpxCli.resolve_strategy() to determine the correct execution method.
  The preferred path is the same `acpx` command available in the user's
  terminal, with a Windows shell fallback for npm shims.

  ACPX command grammar: acpx [global_options] <agent> [subcommand] [subcommand_options]
  Global options MUST appear before the agent subcommand.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.AgentRunner.{AcpxCli, EventParser, ProcessKiller}

  @builtin_agents ~w(claude codex gemini opencode cursor copilot droid iflow kilocode kimi kiro pi openclaw qoder qwen trae)

  @type acpx_options :: %{
          optional(:model) => String.t(),
          optional(:max_turns) => pos_integer(),
          optional(:allowed_tools) => [String.t()],
          optional(:prompt_retries) => non_neg_integer(),
          optional(:system_prompt) => String.t(),
          optional(:system_prompt_append) => String.t(),
          optional(:approve_all) => boolean(),
          optional(:timeout) => pos_integer(),
          optional(:ttl) => non_neg_integer(),
          optional(:suppress_reads) => boolean(),
          optional(:no_terminal) => boolean()
        }

  @type state :: %{
          agent: String.t(),
          cwd: String.t(),
          port: port() | nil,
          os_pid: pos_integer() | nil,
          recipient: pid() | nil,
          issue_id: String.t() | nil,
          session_name: String.t() | nil,
          session_id: String.t() | nil,
          turn_number: non_neg_integer(),
          acpx_options: acpx_options(),
          execution_strategy: AcpxCli.execution_strategy(),
          started_at: DateTime.t() | nil
        }

  @port_line_bytes 1_048_576
  @turn_timeout_ms 600_000
  @max_preview_bytes 2048
  @session_create_timeout_ms 90_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec sessions_ensure(pid(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def sessions_ensure(pid, session_name, cwd \\ ".", opts \\ []) do
    GenServer.call(pid, {:sessions_ensure, session_name, cwd, opts}, @session_create_timeout_ms)
  end

  @spec sessions_new(pid(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def sessions_new(pid, session_name, cwd \\ ".", opts \\ []) do
    GenServer.call(pid, {:sessions_new, session_name, cwd, opts}, @session_create_timeout_ms)
  end

  @spec prompt(pid(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prompt(pid, prompt_text, opts \\ []) do
    GenServer.call(pid, {:prompt, prompt_text, opts}, @turn_timeout_ms)
  end

  @spec sessions_close(pid(), keyword()) :: :ok | {:error, term()}
  def sessions_close(pid, opts \\ []) do
    GenServer.call(pid, {:sessions_close, opts}, 60_000)
  end

  @spec status(pid()) :: {:ok, map()} | {:error, term()}
  def status(pid) do
    GenServer.call(pid, :status, 30_000)
  end

  @spec exec(pid(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def exec(pid, prompt, opts \\ []) do
    GenServer.call(pid, {:exec, prompt, opts}, @turn_timeout_ms)
  end

  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    strategy =
      try do
        AcpxCli.resolve_strategy()
      rescue
        _ -> {:error, "ACPX CLI resolution failed: npm or acpx not found"}
      catch
        _, _ -> {:error, "ACPX CLI resolution failed: npm or acpx not found"}
      end

    case strategy do
      {:error, msg} ->
        Logger.warning("ACPX CLI resolution: #{msg}")

      _ ->
        Logger.info("ACPX execution strategy: #{AcpxCli.strategy_label(strategy)}")
    end

    acpx_opts =
      Keyword.get(opts, :acpx_options, %{})
      |> Map.merge(default_acpx_options())

    state = %{
      agent: Keyword.get(opts, :agent, "claude"),
      cwd: Keyword.get(opts, :cwd, "."),
      port: nil,
      os_pid: nil,
      recipient: Keyword.get(opts, :recipient),
      issue_id: Keyword.get(opts, :issue_id),
      session_name: nil,
      session_id: nil,
      turn_number: 0,
      acpx_options: acpx_opts,
      execution_strategy: strategy,
      started_at: nil
    }

    {:ok, state}
  end

  defp default_acpx_options do
    %{}
  end

  @spec handle_call(:status, GenServer.from(), state()) :: {:reply, {:ok, map()}, state()}
  def handle_call(:status, _from, state) do
    status = %{
      session_name: state.session_name,
      session_id: state.session_id,
      turn_number: state.turn_number,
      cwd: state.cwd,
      agent: state.agent,
      acpx_strategy: AcpxCli.strategy_label(state.execution_strategy)
    }

    {:reply, {:ok, status}, state}
  end

  def handle_call({:sessions_ensure, session_name, cwd, _opts}, _from, state) do
    updated_state = %{state | session_name: session_name, cwd: cwd}

    case do_sessions_ensure(updated_state) do
      {:ok, session_id} ->
        new_state = %{updated_state | session_id: session_id, turn_number: 0}
        {:reply, {:ok, session_id}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:sessions_new, session_name, cwd, _opts}, _from, state) do
    updated_state = %{state | session_name: session_name, cwd: cwd}

    case do_sessions_new(updated_state) do
      {:ok, session_id} ->
        new_state = %{updated_state | session_id: session_id, turn_number: 0}
        {:reply, {:ok, session_id}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:prompt, _prompt_text, _opts}, _from, %{session_name: nil} = state) do
    Logger.error("Cannot send prompt without a session. Call sessions_ensure first.")
    {:reply, {:error, :no_session}, state}
  end

  def handle_call({:prompt, prompt_text, _opts}, _from, state) do
    case do_prompt(state, prompt_text) do
      {:ok, result, events} ->
        Enum.each(events, fn event ->
          send_update(state.recipient, state.issue_id, event)
        end)

        new_state = %{state | turn_number: state.turn_number + 1}
        {:reply, {:ok, result}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:sessions_close, _opts}, _from, %{session_name: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:sessions_close, _opts}, _from, state) do
    case do_sessions_close(state) do
      :ok ->
        new_state = %{state | session_name: nil, session_id: nil}
        {:reply, :ok, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:exec, prompt, _opts}, _from, state) do
    case do_exec(state, prompt) do
      {:ok, result, events} ->
        Enum.each(events, fn event ->
          send_update(state.recipient, state.issue_id, event)
        end)

        new_state = %{state | turn_number: state.turn_number + 1}
        {:reply, {:ok, result}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_info({:DOWN, _ref, :port, port, reason}, state) do
    Logger.debug("Port #{inspect(port)} down after cleanup: #{inspect(reason)}")
    {:noreply, %{state | port: nil}}
  end

  @impl true
  def terminate(_reason, state) do
    cleanup_port(state.port, state.os_pid)
    :ok
  end

  defp do_sessions_ensure(state) do
    case state.execution_strategy do
      {:error, msg} ->
        {:error, {:acpx_cli_resolution_failed, msg}}

      strategy ->
        opts = state.acpx_options
        args = build_sessions_ensure_args(state.agent, state.session_name, opts, state.cwd)

        Logger.info("Ensuring acpx session: #{state.session_name} agent=#{state.agent}")

        case execute_acpx(strategy, args, state.cwd, @session_create_timeout_ms) do
          {:ok, output} ->
            session_id = parse_session_id_from_output(output)
            Logger.info("Ensured acpx session: #{state.session_name} -> #{session_id}")
            {:ok, session_id}

          {:error, _} = error ->
            error
        end
    end
  end

  defp do_sessions_new(state) do
    case state.execution_strategy do
      {:error, msg} ->
        {:error, {:acpx_cli_resolution_failed, msg}}

      strategy ->
        opts = state.acpx_options
        args = build_sessions_new_args(state.agent, state.session_name, opts, state.cwd)

        Logger.info("Creating acpx session: #{state.session_name} agent=#{state.agent}")

        case execute_acpx(strategy, args, state.cwd, @session_create_timeout_ms) do
          {:ok, output} ->
            session_id = parse_session_id_from_output(output)
            Logger.info("Created acpx session: #{state.session_name} -> #{session_id}")
            {:ok, session_id}

          {:error, _} = error ->
            error
        end
    end
  end

  defp do_sessions_close(state) do
    case state.execution_strategy do
      {:error, msg} ->
        {:error, {:acpx_cli_resolution_failed, msg}}

      strategy ->
        agent_sub = agent_subcommand(state.agent)
        args = ["--cwd", state.cwd, agent_sub, "sessions", "close", state.session_name]

        Logger.info("Closing acpx session: #{state.session_name}")

        case execute_acpx(strategy, args, state.cwd, 30_000) do
          {:ok, _output} ->
            Logger.info("Closed acpx session: #{state.session_name}")
            :ok

          {:error, _} = error ->
            error
        end
    end
  end

  defp do_prompt(state, prompt_text) do
    case state.execution_strategy do
      {:error, msg} ->
        {:error, {:acpx_cli_resolution_failed, msg}}

      strategy ->
        opts = state.acpx_options
        tmp_path = write_prompt_tmp(prompt_text)
        args = build_prompt_args(state.agent, state.session_name, tmp_path, opts, state.cwd)

        Logger.info("Sending acpx prompt: session=#{state.session_name} turn=#{state.turn_number}")

        case execute_acpx_streaming(strategy, args, state.cwd, stream_timeout_ms(state), state.recipient, state.issue_id) do
          {:error, _} = error ->
            cleanup_prompt_tmp(tmp_path)
            error

          events ->
            cleanup_prompt_tmp(tmp_path)

            case events do
              [] ->
                {:ok, %{status: "completed", events: []}, []}

              [_ | _] = event_list ->
                result = EventParser.extract_result(event_list)
                {:ok, result, event_list}
            end
        end
    end
  end

  defp do_exec(state, prompt) do
    case state.execution_strategy do
      {:error, msg} ->
        {:error, {:acpx_cli_resolution_failed, msg}}

      strategy ->
        opts = state.acpx_options
        tmp_path = write_prompt_tmp(prompt)
        args = build_exec_args(state.agent, tmp_path, opts, state.cwd)

        case execute_acpx_streaming(strategy, args, state.cwd, stream_timeout_ms(state), state.recipient, state.issue_id) do
          {:error, _} = error ->
            cleanup_prompt_tmp(tmp_path)
            error

          events ->
            cleanup_prompt_tmp(tmp_path)

            case events do
              [] ->
                {:ok, %{status: "completed", events: []}, []}

              [_ | _] = event_list ->
                result = EventParser.extract_result(event_list)
                {:ok, result, event_list}
            end
        end
    end
  end

  defp build_global_args(opts, cwd) do
    args = ["--format", "json", "--json-strict"]
    args = add_cwd_flag(args, cwd)
    args = add_permission_flags(args, opts)
    args = add_acpx_global_flags(args, opts)
    args
  end

  defp add_cwd_flag(args, cwd) when is_binary(cwd) and cwd != "" do
    args ++ ["--cwd", cwd]
  end

  defp add_cwd_flag(args, _cwd) do
    args ++ ["--cwd", "."]
  end

  defp build_sessions_ensure_args(agent, session_name, opts, cwd) do
    agent_sub = agent_subcommand(agent)
    args = build_global_args(opts, cwd)
    args = args ++ [agent_sub, "sessions", "ensure"]

    args =
      if session_name do
        args ++ ["--name", session_name]
      else
        args
      end

    args
  end

  defp build_sessions_new_args(agent, session_name, opts, cwd) do
    agent_sub = agent_subcommand(agent)
    args = build_global_args(opts, cwd)
    args = args ++ [agent_sub, "sessions", "new"]

    args =
      if session_name do
        args ++ ["--name", session_name]
      else
        args
      end

    args
  end

  defp build_prompt_args(agent, session_name, prompt_file_path, opts, cwd) do
    agent_sub = agent_subcommand(agent)
    args = build_global_args(opts, cwd)
    args = args ++ [agent_sub, "prompt", "-s", session_name, "-f", prompt_file_path]
    args
  end

  defp build_exec_args(agent, prompt_file_path, opts, cwd) do
    agent_sub = agent_subcommand(agent)
    args = build_global_args(opts, cwd)
    args = args ++ [agent_sub, "exec", "-f", prompt_file_path]
    args
  end

  defp add_permission_flags(args, opts) do
    approve_all = Map.get(opts, :approve_all, true)

    args =
      if approve_all do
        args ++ ["--approve-all"]
      else
        args
      end

    args ++ ["--non-interactive-permissions", "deny"]
  end

  defp add_acpx_global_flags(args, opts) do
    args
    |> add_flag_if(opts[:model], "--model")
    |> add_flag_if(opts[:max_turns], "--max-turns")
    |> add_flag_if(opts[:allowed_tools], "--allowed-tools")
    |> add_flag_if(opts[:prompt_retries], "--prompt-retries")
    |> add_flag_if(opts[:system_prompt], "--system-prompt")
    |> add_flag_if(opts[:system_prompt_append], "--append-system-prompt")
    |> add_flag_if(opts[:timeout], "--timeout")
    |> add_flag_if(opts[:ttl], "--ttl")
    |> add_bool_flag(opts[:suppress_reads], "--suppress-reads")
    |> add_bool_flag(opts[:no_terminal], "--no-terminal")
  end

  defp add_flag_if(args, nil, _flag), do: args
  defp add_flag_if(args, value, flag) when is_binary(value), do: args ++ [flag, value]
  defp add_flag_if(args, value, flag) when is_integer(value), do: args ++ [flag, Integer.to_string(value)]
  defp add_flag_if(args, value, flag) when is_list(value), do: args ++ [flag, Enum.join(value, ",")]

  defp add_bool_flag(args, true, flag), do: args ++ [flag]
  defp add_bool_flag(args, _, _flag), do: args

  defp execute_acpx(strategy, args, cwd, timeout_ms) do
    {executable, full_args} = build_exec_command(strategy, args)

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(full_args, &String.to_charlist/1),
          cd: String.to_charlist(cwd),
          line: 65536
        ]
      )

    os_pid = port_os_pid(port)

    if is_pid(self()) do
      Process.put(:symphony_port, port)
      Process.put(:symphony_os_pid, os_pid)
    end

    monitor_ref = Port.monitor(port)
    output = collect_command_output(port, monitor_ref, [], timeout_ms)
    cleanup_port(port, os_pid)
    output
  end

  defp execute_acpx_streaming(strategy, args, cwd, timeout_ms, recipient, issue_id) do
    {executable, full_args} = build_exec_command(strategy, args)

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(full_args, &String.to_charlist/1),
          cd: String.to_charlist(cwd),
          line: @port_line_bytes
        ]
      )

    os_pid = port_os_pid(port)

    if is_pid(self()) do
      Process.put(:symphony_port, port)
      Process.put(:symphony_os_pid, os_pid)
    end

    monitor_ref = Port.monitor(port)
    events = collect_output(port, monitor_ref, [], [], [], timeout_ms, recipient, issue_id)
    cleanup_port(port, os_pid)
    events
  end

  defp build_exec_command({:direct, exe}, args) do
    {exe, args}
  end

  defp build_exec_command({:shell, exe, prefix_args}, args) do
    {exe, prefix_args ++ args}
  end

  defp build_exec_command({:node_js, node, js_path}, args) do
    {node, [js_path | args]}
  end

  defp build_exec_command({:error, msg}, _args) do
    raise "ACPX execution strategy error: #{msg}"
  end

  defp collect_command_output(port, monitor_ref, acc, timeout_ms) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        collect_command_output(port, monitor_ref, [line | acc], timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        collect_command_output(port, monitor_ref, acc ++ [to_string(chunk)], timeout_ms)

      {^port, {:exit_status, 0}} ->
        {:ok, Enum.join(Enum.reverse(acc), "\n")}

      {^port, {:exit_status, status}} ->
        {:error, classify_exit_status(status, Enum.join(Enum.reverse(acc), "\n"))}

      {:DOWN, ^monitor_ref, :port, ^port, _reason} ->
        cleanup_port(port)
        {:error, :port_died}
    after
      timeout_ms ->
        cleanup_port(port)
        {:error, :timeout}
    end
  end

  defp classify_exit_status(0, _), do: :success
  defp classify_exit_status(1, output), do: {:agent_error, 1, output}
  defp classify_exit_status(2, output), do: {:usage_error, 2, output}
  defp classify_exit_status(3, _), do: {:timeout, 3}
  defp classify_exit_status(4, _), do: {:no_session, 4}
  defp classify_exit_status(5, _), do: {:permission_denied, 5}
  defp classify_exit_status(130, _), do: {:interrupted, 130}
  defp classify_exit_status(status, output), do: {:exit_status, status, output}

  defp parse_session_id_from_output(output) do
    output
    |> String.trim()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn line ->
      String.starts_with?(line, "{") and String.contains?(line, "acpxRecordId")
    end)
    |> List.first()
    |> case do
      nil ->
        output
        |> String.trim()
        |> String.split("\n")
        |> List.first()
        |> String.trim()

      json_line ->
        case Jason.decode(json_line) do
          {:ok, %{"acpxRecordId" => id}} ->
            id

          {:ok, %{"result" => %{"acpxRecordId" => id}}} ->
            id

          {:ok, %{"result" => %{"acpxSessionId" => id}}} ->
            id

          _ ->
            output |> String.trim() |> String.split("\n") |> List.first() |> String.trim()
        end
    end
  end

  defp write_prompt_tmp(prompt_text) when is_binary(prompt_text) do
    dir = System.tmp_dir!()
    File.mkdir_p!(dir)
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    path = Path.join(dir, "symphony-prompt-#{id}.txt")
    File.write!(path, prompt_text)
    path
  end

  defp cleanup_prompt_tmp(path) when is_binary(path) do
    File.rm(path)
  end

  defp cleanup_prompt_tmp(_), do: :ok

  defp stream_timeout_ms(%{acpx_options: %{timeout: timeout_seconds}})
       when is_integer(timeout_seconds) and timeout_seconds > 0 do
    timeout_seconds * 1000 + 30_000
  end

  defp stream_timeout_ms(_state), do: @turn_timeout_ms

  defp collect_output(port, monitor_ref, acc, raw_acc, _pending, timeout_ms, nil, _issue_id) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        line = to_string(line)

        case EventParser.parse(line) do
          {:ok, event} -> collect_output(port, monitor_ref, [event | acc], [line | raw_acc], "", timeout_ms, nil, nil)
          {:error, reason} -> collect_output(port, monitor_ref, acc, [line | raw_acc], "", timeout_ms, nil, {:parse_error, reason})
        end

      {^port, {:data, {:noeol, chunk}}} ->
        collect_output(port, monitor_ref, acc, raw_acc, to_string(chunk), timeout_ms, nil, nil)

      {^port, {:exit_status, 0}} ->
        Enum.reverse(acc)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, classify_exit_status(status, raw_output(raw_acc))}}

      {:DOWN, ^monitor_ref, :port, ^port, _reason} ->
        cleanup_port(port)
        {:error, :port_died}
    after
      timeout_ms ->
        cleanup_port(port)
        {:error, :timeout}
    end
  end

  defp collect_output(port, monitor_ref, acc, raw_acc, pending, timeout_ms, recipient, issue_id) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        complete_line = pending <> to_string(line)

        case EventParser.parse(complete_line) do
          {:ok, event} ->
            collect_output(port, monitor_ref, [event | acc], [complete_line | raw_acc], "", timeout_ms, recipient, issue_id)
          {:error, reason} ->
            send_parser_error(recipient, issue_id, reason, complete_line)
            collect_output(port, monitor_ref, acc, [complete_line | raw_acc], "", timeout_ms, recipient, issue_id)
        end

      {^port, {:data, {:noeol, chunk}}} ->
        collect_output(port, monitor_ref, acc, raw_acc, pending <> to_string(chunk), timeout_ms, recipient, issue_id)

      {^port, {:exit_status, 0}} ->
        Enum.reverse(acc)

      {^port, {:exit_status, status}} ->
        raw_acc = maybe_prepend_pending(raw_acc, pending)
        {:error, {:port_exit, classify_exit_status(status, raw_output(raw_acc))}}

      {:DOWN, ^monitor_ref, :port, ^port, _reason} ->
        cleanup_port(port)
        {:error, :port_died}
    after
      timeout_ms ->
        cleanup_port(port)
        {:error, :timeout}
    end
  end

  defp maybe_prepend_pending(raw_acc, ""), do: raw_acc
  defp maybe_prepend_pending(raw_acc, pending), do: [pending | raw_acc]

  defp raw_output(raw_acc) do
    raw_acc
    |> Enum.reverse()
    |> Enum.join("\n")
    |> String.trim()
  end

  defp send_update(nil, _issue_id, _event), do: :ok

  defp send_update(recipient, issue_id, %{type: type, data: data} = _event) do
    adapted = adapt_acpx_event(type, data)
    send(recipient, {:agent_worker_update, issue_id, adapted})
  end

  defp send_update(recipient, issue_id, event) do
    send(recipient, {:agent_worker_update, issue_id, event})
  end

  defp send_parser_error(recipient, issue_id, reason, raw_line) do
    preview = truncate_text(raw_line, 200)
    send(recipient, {:agent_worker_update, issue_id, %{
      event: :parser_error,
      timestamp: DateTime.utc_now(),
      raw_event_at: DateTime.utc_now(),
      raw_preview: preview,
      payload: %{parse_error: inspect(reason)}
    }})
  end

  defp adapt_acpx_event(:session_update, data) do
    now = DateTime.utc_now()
    %{event: :session_started, timestamp: now, session_id: data["sessionId"], payload: data,
      raw_event_at: now, raw_preview: build_bounded_preview(data)}
  end

  defp adapt_acpx_event(:agent_message_chunk, data) do
    now = DateTime.utc_now()
    %{event: :agent_message, timestamp: now, payload: data,
      raw_event_at: now, raw_preview: build_bounded_preview(data)}
  end

  defp adapt_acpx_event(:agent_thought_chunk, data) do
    now = DateTime.utc_now()
    %{event: :agent_thought, timestamp: now, payload: data,
      raw_event_at: now, raw_preview: build_bounded_preview(data)}
  end

  defp adapt_acpx_event(:tool_call, data) do
    now = DateTime.utc_now()
    %{event: :tool_call, timestamp: now, payload: data,
      raw_event_at: now, raw_preview: build_bounded_preview(data)}
  end

  defp adapt_acpx_event(:tool_call_update, data) do
    now = DateTime.utc_now()
    %{event: :tool_call_update, timestamp: now, payload: data,
      raw_event_at: now, raw_preview: build_bounded_preview(data)}
  end

  defp adapt_acpx_event(:tool_result, data) do
    now = DateTime.utc_now()
    %{event: :tool_result, timestamp: now, payload: data,
      raw_event_at: now, raw_preview: build_bounded_preview(data)}
  end

  defp adapt_acpx_event(:usage_update, data) do
    now = DateTime.utc_now()
    %{event: :usage_update, timestamp: now, usage: extract_usage_from_acpx(data), payload: data,
      raw_event_at: now, raw_preview: build_bounded_preview(data)}
  end

  defp adapt_acpx_event(:result, data) do
    now = DateTime.utc_now()
    %{event: :turn_completed, timestamp: now, usage: extract_usage_from_acpx(data["usage"]), payload: data,
      raw_event_at: now, raw_preview: build_bounded_preview(data)}
  end

  defp adapt_acpx_event(:error, data) do
    now = DateTime.utc_now()
    %{event: :error, timestamp: now, payload: data,
      raw_event_at: now, raw_preview: build_bounded_preview(data)}
  end

  defp adapt_acpx_event(_type, data) do
    now = DateTime.utc_now()
    %{event: :unknown, timestamp: now, payload: data,
      raw_event_at: now, raw_preview: build_bounded_preview(data)}
  end

  defp build_bounded_preview(data) when is_map(data) do
    text = data["content"] || data["message"] || data["update"] || data["text"] || inspect(data)
    truncate_text(text, @max_preview_bytes)
  end

  defp build_bounded_preview(data) when is_binary(data) do
    truncate_text(data, @max_preview_bytes)
  end

  defp build_bounded_preview(_), do: nil

  defp truncate_text(text, max_bytes) when is_binary(text) do
    if byte_size(text) <= max_bytes do
      text
    else
      String.slice(text, 0, div(max_bytes, 2) - 3) <> "..."
    end
  end

  defp truncate_text(text, max_bytes), do: truncate_text(to_string(text), max_bytes)

  defp extract_usage_from_acpx(nil), do: %{}

  defp extract_usage_from_acpx(usage) when is_map(usage) do
    %{
      input_tokens: usage["inputTokens"] || usage["input_tokens"] || 0,
      output_tokens: usage["outputTokens"] || usage["output_tokens"] || 0,
      total_tokens: usage["totalTokens"] || usage["total_tokens"] || 0,
      cached_read_tokens: usage["cachedReadTokens"] || 0,
      cached_write_tokens: usage["cachedWriteTokens"] || 0
    }
  end

  defp extract_usage_from_acpx(_), do: %{}

  defp agent_subcommand(agent) when agent in @builtin_agents, do: agent
  defp agent_subcommand(agent) when is_binary(agent), do: agent

  defp cleanup_port(port, _os_pid) do
    # Use Process.delete to ensure idempotency: if this os_pid was already
    # cleaned up (e.g. via a concurrent timeout path), skip the kill.
    stored_os_pid = Process.delete(:symphony_os_pid)

    if is_integer(stored_os_pid) and stored_os_pid > 0 do
      ProcessKiller.kill_tree(stored_os_pid)
    end

    close_port(port)
  end

  defp cleanup_port(port) when is_port(port) do
    os_pid = Process.delete(:symphony_os_pid)

    if is_integer(os_pid) and os_pid > 0 do
      ProcessKiller.kill_tree(os_pid)
    end

    close_port(port)
  end

  defp cleanup_port(_port), do: :ok

  defp close_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
        rescue
          ArgumentError -> :ok
        end
    end
  end

  defp close_port(_port), do: :ok

  defp port_os_pid(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 ->
        os_pid

      _ ->
        nil
    end
  end

  defp port_os_pid(_port), do: nil

  @doc false
  def __testing__ do
    %{
      build_exec_command: &build_exec_command/2,
      build_global_args: &build_global_args/2,
      build_sessions_ensure_args: &build_sessions_ensure_args/4,
      build_sessions_new_args: &build_sessions_new_args/4,
      build_prompt_args: &build_prompt_args/5,
      build_exec_args: &build_exec_args/4,
      classify_exit_status: &classify_exit_status/2,
      parse_session_id_from_output: &parse_session_id_from_output/1,
      agent_subcommand: &agent_subcommand/1,
      adapt_acpx_event: &adapt_acpx_event/2,
      extract_usage_from_acpx: &extract_usage_from_acpx/1,
      send_parser_error: &send_parser_error/4
    }
  end
end

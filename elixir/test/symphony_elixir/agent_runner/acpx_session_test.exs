defmodule SymphonyElixir.AgentRunner.AcpxSessionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRunner.AcpxSession

  @builtin_agents ~w(claude codex gemini opencode cursor copilot droid iflow kilocode kimi kiro pi openclaw qoder qwen trae)

  describe "init/1" do
    test "initializes with default agent" do
      assert {:ok, state} = AcpxSession.init([])
      assert state.agent == "claude"
    end

    test "initializes with custom agent" do
      assert {:ok, state} = AcpxSession.init(agent: "codex")
      assert state.agent == "codex"
    end

    test "initializes with default cwd" do
      assert {:ok, state} = AcpxSession.init([])
      assert state.cwd == "."
    end

    test "initializes with custom cwd" do
      assert {:ok, state} = AcpxSession.init(cwd: "/tmp/workspace")
      assert state.cwd == "/tmp/workspace"
    end

    test "initializes session fields as nil" do
      assert {:ok, state} = AcpxSession.init([])
      assert state.session_name == nil
      assert state.session_id == nil
    end

    test "initializes turn_number to 0" do
      assert {:ok, state} = AcpxSession.init([])
      assert state.turn_number == 0
    end

    test "initializes port as nil" do
      assert {:ok, state} = AcpxSession.init([])
      assert state.port == nil
    end

    test "stores issue_id" do
      assert {:ok, state} = AcpxSession.init(issue_id: "PROJ-42")
      assert state.issue_id == "PROJ-42"
    end

    test "issue_id defaults to nil" do
      assert {:ok, state} = AcpxSession.init([])
      assert state.issue_id == nil
    end

    test "stores recipient pid" do
      recipient = self()
      assert {:ok, state} = AcpxSession.init(recipient: recipient)
      assert state.recipient == recipient
    end

    test "recipient defaults to nil" do
      assert {:ok, state} = AcpxSession.init([])
      assert state.recipient == nil
    end

    test "resolves execution strategy" do
      assert {:ok, state} = AcpxSession.init([])
      assert state.execution_strategy != nil

      assert match?({:direct, _}, state.execution_strategy) or
               match?({:shell, _, _}, state.execution_strategy) or
               match?({:node_js, _, _}, state.execution_strategy) or
               match?({:error, _}, state.execution_strategy)
    end

    test "merges acpx_options with defaults" do
      assert {:ok, state} = AcpxSession.init(acpx_options: %{model: "gpt-4o"})
      assert state.acpx_options.model == "gpt-4o"
    end

    test "acpx_options defaults to empty map" do
      assert {:ok, state} = AcpxSession.init([])
      assert state.acpx_options == %{}
    end
  end

  describe "GenServer public API" do
    setup do
      {:ok, pid} = GenServer.start(AcpxSession, agent: "claude", cwd: ".")

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5000)
      end)

      {:ok, pid: pid}
    end

    test "status/1 returns session info", %{pid: pid} do
      assert {:ok, status} = AcpxSession.status(pid)
      assert status.session_name == nil
      assert status.session_id == nil
      assert status.turn_number == 0
      assert status.agent == "claude"
      assert is_binary(status.acpx_strategy)
    end

    test "prompt/2 without session returns :no_session error", %{pid: pid} do
      assert {:error, :no_session} = AcpxSession.prompt(pid, "hello world")
    end

    test "sessions_close/1 without active session returns :ok", %{pid: pid} do
      assert :ok = AcpxSession.sessions_close(pid)
    end

    test "sessions_ensure/3 with error strategy returns error", %{pid: pid} do
      state = :sys.get_state(pid)

      if match?({:error, _}, state.execution_strategy) do
        assert {:error, _} = AcpxSession.sessions_ensure(pid, "test-session", ".")
      end
    end

    test "sessions_new/3 with error strategy returns error", %{pid: pid} do
      state = :sys.get_state(pid)

      if match?({:error, _}, state.execution_strategy) do
        assert {:error, _} = AcpxSession.sessions_new(pid, "test-session", ".")
      end
    end
  end

  describe "build_exec_command/2 (private logic)" do
    test "direct strategy passes executable and args through" do
      strategy = {:direct, "/usr/local/bin/acpx"}
      args = ["--format", "json", "claude", "sessions", "ensure"]

      {exec, full_args} = build_exec_command(strategy, args)

      assert exec == "/usr/local/bin/acpx"
      assert full_args == args
    end

    test "node_js strategy prepends js path to args" do
      strategy = {:node_js, "C:\\nodejs\\node.exe", "C:\\npm\\node_modules\\acpx\\dist\\cli.js"}
      args = ["--format", "json", "claude", "sessions", "ensure"]

      {exec, full_args} = build_exec_command(strategy, args)

      assert exec == "C:\\nodejs\\node.exe"
      assert hd(full_args) == "C:\\npm\\node_modules\\acpx\\dist\\cli.js"
      assert tl(full_args) == args
    end

    test "error strategy raises" do
      strategy = {:error, "acpx not found"}

      assert_raise RuntimeError, ~r/ACPX execution strategy error/, fn ->
        build_exec_command(strategy, [])
      end
    end
  end

  describe "build_global_args/1 (private logic)" do
    test "builds minimal global args with empty options" do
      args = build_global_args(%{})

      assert args == [
               "--format",
               "json",
               "--json-strict",
               "--cwd",
               ".",
               "--approve-all",
               "--non-interactive-permissions",
               "deny"
             ]
    end

    test "includes custom cwd from options" do
      args = build_global_args(%{cwd: "/project/root"})

      assert Enum.at(args, 4) == "/project/root"
    end

    test "omits --approve-all when approve_all is false" do
      args = build_global_args(%{approve_all: false})

      refute "--approve-all" in args
      assert "--non-interactive-permissions" in args
    end

    test "includes --approve-all when approve_all is true" do
      args = build_global_args(%{approve_all: true})

      assert "--approve-all" in args
    end

    test "always includes --non-interactive-permissions deny" do
      args = build_global_args(%{})

      idx = Enum.find_index(args, &(&1 == "--non-interactive-permissions"))
      assert Enum.at(args, idx + 1) == "deny"
    end

    test "adds --model flag when model is set" do
      args = build_global_args(%{model: "gpt-4o"})

      assert "--model" in args
      idx = Enum.find_index(args, &(&1 == "--model"))
      assert Enum.at(args, idx + 1) == "gpt-4o"
    end

    test "adds --max-turns flag when max_turns is set" do
      args = build_global_args(%{max_turns: 10})

      assert "--max-turns" in args
      idx = Enum.find_index(args, &(&1 == "--max-turns"))
      assert Enum.at(args, idx + 1) == "10"
    end

    test "adds --allowed-tools flag with comma-joined list" do
      args = build_global_args(%{allowed_tools: ["read", "write", "bash"]})

      assert "--allowed-tools" in args
      idx = Enum.find_index(args, &(&1 == "--allowed-tools"))
      assert Enum.at(args, idx + 1) == "read,write,bash"
    end

    test "adds --system-prompt flag when system_prompt is set" do
      args = build_global_args(%{system_prompt: "You are helpful."})

      assert "--system-prompt" in args
      idx = Enum.find_index(args, &(&1 == "--system-prompt"))
      assert Enum.at(args, idx + 1) == "You are helpful."
    end

    test "adds --append-system-prompt flag when system_prompt_append is set" do
      args = build_global_args(%{system_prompt_append: "Be concise."})

      assert "--append-system-prompt" in args
      idx = Enum.find_index(args, &(&1 == "--append-system-prompt"))
      assert Enum.at(args, idx + 1) == "Be concise."
    end

    test "adds --timeout flag in seconds when timeout is set" do
      args = build_global_args(%{timeout: 120})

      assert "--timeout" in args
      idx = Enum.find_index(args, &(&1 == "--timeout"))
      assert Enum.at(args, idx + 1) == "120"
    end

    test "adds --ttl flag when ttl is set" do
      args = build_global_args(%{ttl: 3600})

      assert "--ttl" in args
      idx = Enum.find_index(args, &(&1 == "--ttl"))
      assert Enum.at(args, idx + 1) == "3600"
    end

    test "adds --prompt-retries flag when prompt_retries is set" do
      args = build_global_args(%{prompt_retries: 3})

      assert "--prompt-retries" in args
      idx = Enum.find_index(args, &(&1 == "--prompt-retries"))
      assert Enum.at(args, idx + 1) == "3"
    end

    test "adds --suppress-reads flag when suppress_reads is true" do
      args = build_global_args(%{suppress_reads: true})

      assert "--suppress-reads" in args
    end

    test "omits --suppress-reads flag when suppress_reads is false" do
      args = build_global_args(%{suppress_reads: false})

      refute "--suppress-reads" in args
    end

    test "adds --no-terminal flag when no_terminal is true" do
      args = build_global_args(%{no_terminal: true})

      assert "--no-terminal" in args
    end

    test "omits --no-terminal flag when no_terminal is false" do
      args = build_global_args(%{no_terminal: false})

      refute "--no-terminal" in args
    end

    test "global flags appear before agent subcommand position" do
      args = build_global_args(%{})
      sessions_args = args ++ ["claude", "sessions", "ensure", "--name", "test"]

      format_idx = Enum.find_index(sessions_args, &(&1 == "--format"))
      agent_idx = Enum.find_index(sessions_args, &(&1 == "claude"))
      assert format_idx < agent_idx
    end

    test "omits all optional flags when options are nil" do
      args =
        build_global_args(%{
          model: nil,
          max_turns: nil,
          allowed_tools: nil,
          prompt_retries: nil,
          system_prompt: nil,
          system_prompt_append: nil,
          timeout: nil,
          ttl: nil,
          suppress_reads: nil,
          no_terminal: nil
        })

      refute "--model" in args
      refute "--max-turns" in args
      refute "--allowed-tools" in args
      refute "--prompt-retries" in args
      refute "--system-prompt" in args
      refute "--append-system-prompt" in args
      refute "--timeout" in args
      refute "--ttl" in args
      refute "--suppress-reads" in args
      refute "--no-terminal" in args
    end
  end

  describe "build_sessions_ensure_args/3 (private logic)" do
    test "builds correct argument sequence" do
      args = build_sessions_ensure_args("claude", "my-session", %{})

      assert Enum.chunk_every(args, 2, 1)
             |> Enum.any?(fn [k, v] ->
               k == "--name" and v == "my-session"
             end)

      agent_idx = Enum.find_index(args, &(&1 == "claude"))
      sessions_idx = Enum.find_index(args, &(&1 == "sessions"))
      ensure_idx = Enum.find_index(args, &(&1 == "ensure"))

      assert agent_idx != nil
      assert sessions_idx == agent_idx + 1
      assert ensure_idx == sessions_idx + 1
    end

    test "omits --name when session_name is nil" do
      args = build_sessions_ensure_args("claude", nil, %{})

      refute "--name" in args
    end

    test "uses agent subcommand for known agents" do
      args = build_sessions_ensure_args("codex", "test", %{})

      assert "codex" in args
    end
  end

  describe "build_sessions_new_args/3 (private logic)" do
    test "builds correct argument sequence with 'new' subcommand" do
      args = build_sessions_new_args("claude", "fresh-session", %{})

      assert "new" in args
      assert "--name" in args

      new_idx = Enum.find_index(args, &(&1 == "new"))
      sessions_idx = Enum.find_index(args, &(&1 == "sessions"))
      assert new_idx == sessions_idx + 1
    end

    test "omits --name when session_name is nil" do
      args = build_sessions_new_args("claude", nil, %{})

      refute "--name" in args
    end
  end

  describe "build_prompt_args/4 (private logic)" do
    test "builds prompt args with session and file path" do
      args = build_prompt_args("claude", "my-session", "/tmp/prompt.txt", %{})

      assert "prompt" in args
      assert "-s" in args
      assert "-f" in args

      s_idx = Enum.find_index(args, &(&1 == "-s"))
      assert Enum.at(args, s_idx + 1) == "my-session"

      f_idx = Enum.find_index(args, &(&1 == "-f"))
      assert Enum.at(args, f_idx + 1) == "/tmp/prompt.txt"
    end
  end

  describe "build_exec_args/3 (private logic)" do
    test "builds exec args with file path but no session" do
      args = build_exec_args("claude", "/tmp/prompt.txt", %{})

      assert "exec" in args
      assert "-f" in args
      refute "-s" in args

      f_idx = Enum.find_index(args, &(&1 == "-f"))
      assert Enum.at(args, f_idx + 1) == "/tmp/prompt.txt"
    end
  end

  describe "classify_exit_status/2 (private logic)" do
    test "exit code 0 is :success" do
      assert classify_exit_status(0, "") == :success
    end

    test "exit code 1 is :agent_error with output" do
      assert classify_exit_status(1, "something went wrong") ==
               {:agent_error, 1, "something went wrong"}
    end

    test "exit code 2 is :usage_error with output" do
      assert classify_exit_status(2, "bad flag") ==
               {:usage_error, 2, "bad flag"}
    end

    test "exit code 3 is :timeout" do
      assert classify_exit_status(3, "") == {:timeout, 3}
    end

    test "exit code 4 is :no_session" do
      assert classify_exit_status(4, "") == {:no_session, 4}
    end

    test "exit code 5 is :permission_denied" do
      assert classify_exit_status(5, "") == {:permission_denied, 5}
    end

    test "exit code 130 is :interrupted" do
      assert classify_exit_status(130, "") == {:interrupted, 130}
    end

    test "unknown exit code is generic :exit_status" do
      assert classify_exit_status(99, "mystery output") ==
               {:exit_status, 99, "mystery output"}
    end

    test "exit code 1 preserves output for debugging" do
      output = "Error: agent failed with details"
      assert {:agent_error, 1, ^output} = classify_exit_status(1, output)
    end

    test "exit code 2 preserves output for debugging" do
      output = "Usage: acpx [options] <agent>"
      assert {:usage_error, 2, ^output} = classify_exit_status(2, output)
    end
  end

  describe "parse_session_id_from_output/1 (private logic)" do
    test "parses top-level acpxRecordId from JSON" do
      output = ~s({"acpxRecordId":"sess-abc123","status":"created"})

      assert parse_session_id_from_output(output) == "sess-abc123"
    end

    test "parses nested acpxRecordId from result object" do
      output = ~s({"result":{"acpxRecordId":"sess-xyz789"}})

      assert parse_session_id_from_output(output) == "sess-xyz789"
    end

    test "parses nested acpxSessionId when line contains acpxRecordId substring but no key" do
      output = ~s({"note":"see acpxRecordId docs","result":{"acpxSessionId":"sess-def456"}})

      assert parse_session_id_from_output(output) == "sess-def456"
    end

    test "falls back to first line when no JSON with acpxRecordId" do
      output = "sess-plain-id"

      assert parse_session_id_from_output(output) == "sess-plain-id"
    end

    test "falls back to first line when JSON has no acpxRecordId" do
      output = ~s({"status":"ok","message":"done"})

      assert parse_session_id_from_output(output) == ~s({"status":"ok","message":"done"})
    end

    test "falls back to first line when JSON has acpxSessionId but no acpxRecordId" do
      output = ~s({"result":{"acpxSessionId":"sess-only"}})

      assert parse_session_id_from_output(output) == ~s({"result":{"acpxSessionId":"sess-only"}})
    end

    test "extracts JSON line from multi-line output" do
      output = "Some log output\n{\"acpxRecordId\":\"sess-multi\",\"status\":\"created\"}\nMore output"

      assert parse_session_id_from_output(output) == "sess-multi"
    end

    test "handles leading whitespace in JSON line" do
      output = "   {\"acpxRecordId\":\"sess-whitespace\"}"

      assert parse_session_id_from_output(output) == "sess-whitespace"
    end

    test "handles empty output" do
      assert parse_session_id_from_output("") == ""
    end

    test "handles output with only whitespace" do
      assert parse_session_id_from_output("   \n  \n  ") == ""
    end

    test "prefers first JSON line with acpxRecordId" do
      output = "{\"other\":\"data\"}\n{\"acpxRecordId\":\"sess-first-match\"}\n{\"acpxRecordId\":\"sess-second-match\"}"

      assert parse_session_id_from_output(output) == "sess-first-match"
    end

    test "returns integer acpxRecordId when value is not a string" do
      output = ~s({"acpxRecordId":12345})

      assert parse_session_id_from_output(output) == 12345
    end
  end

  describe "agent_subcommand/1 (private logic)" do
    test "all builtin agents map to themselves" do
      for agent <- @builtin_agents do
        assert agent_subcommand(agent) == agent
      end
    end

    test "non-builtin agent string passes through" do
      assert agent_subcommand("custom-agent") == "custom-agent"
    end

    test "empty string passes through" do
      assert agent_subcommand("") == ""
    end
  end

  describe "do_sessions_close arg structure (private logic)" do
    test "close args use sessions close subcommand with session name" do
      agent_sub = agent_subcommand("claude")
      args = ["--cwd", "/project", agent_sub, "sessions", "close", "my-session"]

      assert Enum.at(args, 0) == "--cwd"
      assert Enum.at(args, 1) == "/project"
      assert Enum.at(args, 2) == "claude"
      assert Enum.at(args, 3) == "sessions"
      assert Enum.at(args, 4) == "close"
      assert Enum.at(args, 5) == "my-session"
    end
  end

  describe "adapt_acpx_event/2 (private logic)" do
    test "session_update event includes session_id from data" do
      data = %{"sessionId" => "sess-123"}
      result = adapt_acpx_event(:session_update, data)

      assert result.event == :session_started
      assert result.session_id == "sess-123"
      assert result.payload == data
    end

    test "agent_message_chunk event maps to :agent_message" do
      data = %{"content" => "hello"}
      result = adapt_acpx_event(:agent_message_chunk, data)

      assert result.event == :agent_message
      assert result.payload == data
    end

    test "agent_thought_chunk event maps to :agent_thought" do
      data = %{"content" => "thinking..."}
      result = adapt_acpx_event(:agent_thought_chunk, data)

      assert result.event == :agent_thought
      assert result.payload == data
    end

    test "tool_call event maps to :tool_call" do
      data = %{"name" => "read_file"}
      result = adapt_acpx_event(:tool_call, data)

      assert result.event == :tool_call
      assert result.payload == data
    end

    test "tool_call_update event maps to :tool_call_update" do
      data = %{"progress" => 50}
      result = adapt_acpx_event(:tool_call_update, data)

      assert result.event == :tool_call_update
      assert result.payload == data
    end

    test "tool_result event maps to :tool_result" do
      data = %{"output" => "file contents"}
      result = adapt_acpx_event(:tool_result, data)

      assert result.event == :tool_result
      assert result.payload == data
    end

    test "usage_update event extracts usage" do
      data = %{"inputTokens" => 100, "outputTokens" => 50}
      result = adapt_acpx_event(:usage_update, data)

      assert result.event == :usage_update
      assert result.usage.input_tokens == 100
      assert result.usage.output_tokens == 50
    end

    test "result event maps to :turn_completed" do
      data = %{"usage" => %{"inputTokens" => 200, "outputTokens" => 100}}
      result = adapt_acpx_event(:result, data)

      assert result.event == :turn_completed
      assert result.usage.input_tokens == 200
    end

    test "error event maps to :error" do
      data = %{"message" => "something failed"}
      result = adapt_acpx_event(:error, data)

      assert result.event == :error
      assert result.payload == data
    end

    test "unknown event type maps to :unknown" do
      data = %{"foo" => "bar"}
      result = adapt_acpx_event(:custom_type, data)

      assert result.event == :unknown
      assert result.payload == data
    end

    test "all adapted events include timestamp" do
      for type <- [:session_update, :agent_message_chunk, :tool_call, :error, :unknown] do
        result = adapt_acpx_event(type, %{})
        assert %DateTime{} = result.timestamp
      end
    end
  end

  describe "extract_usage_from_acpx/1 (private logic)" do
    test "extracts camelCase usage fields" do
      usage = %{
        "inputTokens" => 100,
        "outputTokens" => 50,
        "totalTokens" => 150,
        "cachedReadTokens" => 20,
        "cachedWriteTokens" => 10
      }

      result = extract_usage_from_acpx(usage)

      assert result.input_tokens == 100
      assert result.output_tokens == 50
      assert result.total_tokens == 150
      assert result.cached_read_tokens == 20
      assert result.cached_write_tokens == 10
    end

    test "extracts snake_case usage fields" do
      usage = %{
        "input_tokens" => 200,
        "output_tokens" => 80,
        "total_tokens" => 280
      }

      result = extract_usage_from_acpx(usage)

      assert result.input_tokens == 200
      assert result.output_tokens == 80
      assert result.total_tokens == 280
    end

    test "prefers camelCase over snake_case" do
      usage = %{"inputTokens" => 100, "input_tokens" => 200}

      result = extract_usage_from_acpx(usage)

      assert result.input_tokens == 100
    end

    test "defaults missing fields to 0" do
      usage = %{"inputTokens" => 50}

      result = extract_usage_from_acpx(usage)

      assert result.input_tokens == 50
      assert result.output_tokens == 0
      assert result.total_tokens == 0
      assert result.cached_read_tokens == 0
      assert result.cached_write_tokens == 0
    end

    test "returns empty map for nil" do
      assert extract_usage_from_acpx(nil) == %{}
    end

    test "returns empty map for non-map input" do
      assert extract_usage_from_acpx("not a map") == %{}
      assert extract_usage_from_acpx(42) == %{}
    end

    test "returns empty map for empty map" do
      result = extract_usage_from_acpx(%{})

      assert result.input_tokens == 0
      assert result.output_tokens == 0
      assert result.total_tokens == 0
      assert result.cached_read_tokens == 0
      assert result.cached_write_tokens == 0
    end
  end

  defp build_exec_command({:direct, exe}, args), do: {exe, args}
  defp build_exec_command({:shell, exe, prefix_args}, args), do: {exe, prefix_args ++ args}
  defp build_exec_command({:node_js, node, js_path}, args), do: {node, [js_path | args]}
  defp build_exec_command({:error, msg}, _args), do: raise("ACPX execution strategy error: #{msg}")

  defp build_global_args(opts) do
    args = ["--format", "json", "--json-strict"]
    args = add_cwd_flag(args, opts)
    args = add_permission_flags(args, opts)
    add_acpx_global_flags(args, opts)
  end

  defp add_cwd_flag(args, opts) do
    cwd = opts[:cwd] || "."
    args ++ ["--cwd", cwd]
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

  defp build_sessions_ensure_args(agent, session_name, opts) do
    agent_sub = agent_subcommand(agent)
    args = build_global_args(opts)
    args = args ++ [agent_sub, "sessions", "ensure"]

    if session_name do
      args ++ ["--name", session_name]
    else
      args
    end
  end

  defp build_sessions_new_args(agent, session_name, opts) do
    agent_sub = agent_subcommand(agent)
    args = build_global_args(opts)
    args = args ++ [agent_sub, "sessions", "new"]

    if session_name do
      args ++ ["--name", session_name]
    else
      args
    end
  end

  defp build_prompt_args(agent, session_name, prompt_file_path, opts) do
    agent_sub = agent_subcommand(agent)
    args = build_global_args(opts)
    args ++ [agent_sub, "prompt", "-s", session_name, "-f", prompt_file_path]
  end

  defp build_exec_args(agent, prompt_file_path, opts) do
    agent_sub = agent_subcommand(agent)
    args = build_global_args(opts)
    args ++ [agent_sub, "exec", "-f", prompt_file_path]
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

  defp agent_subcommand(agent) when agent in @builtin_agents, do: agent
  defp agent_subcommand(agent) when is_binary(agent), do: agent

  defp adapt_acpx_event(:session_update, data) do
    %{event: :session_started, timestamp: DateTime.utc_now(), session_id: data["sessionId"], payload: data}
  end

  defp adapt_acpx_event(:agent_message_chunk, data) do
    %{event: :agent_message, timestamp: DateTime.utc_now(), payload: data}
  end

  defp adapt_acpx_event(:agent_thought_chunk, data) do
    %{event: :agent_thought, timestamp: DateTime.utc_now(), payload: data}
  end

  defp adapt_acpx_event(:tool_call, data) do
    %{event: :tool_call, timestamp: DateTime.utc_now(), payload: data}
  end

  defp adapt_acpx_event(:tool_call_update, data) do
    %{event: :tool_call_update, timestamp: DateTime.utc_now(), payload: data}
  end

  defp adapt_acpx_event(:tool_result, data) do
    %{event: :tool_result, timestamp: DateTime.utc_now(), payload: data}
  end

  defp adapt_acpx_event(:usage_update, data) do
    %{event: :usage_update, timestamp: DateTime.utc_now(), usage: extract_usage_from_acpx(data), payload: data}
  end

  defp adapt_acpx_event(:result, data) do
    %{event: :turn_completed, timestamp: DateTime.utc_now(), usage: extract_usage_from_acpx(data["usage"]), payload: data}
  end

  defp adapt_acpx_event(:error, data) do
    %{event: :error, timestamp: DateTime.utc_now(), payload: data}
  end

  defp adapt_acpx_event(_type, data) do
    %{event: :unknown, timestamp: DateTime.utc_now(), payload: data}
  end

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
end

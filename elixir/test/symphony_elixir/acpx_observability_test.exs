defmodule SymphonyElixir.ACPXObservabilityTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRunner.AcpxSession
  alias SymphonyElixir.AgentRunner.EventParser
  alias SymphonyElixir.Config
  alias SymphonyElixir.Orchestrator

  describe "ACPX event stream observability" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "symphony-obs-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
      end)

      {:ok, tmp_dir: tmp_dir}
    end

    test "adapt_acpx_event sets raw_event_at and raw_preview for agent_message_chunk" do
      data = %{"content" => "Hello from agent"}
      adapted = AcpxSession.__testing__().adapt_acpx_event.(:agent_message_chunk, data)

      assert Map.has_key?(adapted, :raw_event_at)
      assert adapted.raw_event_at != nil
      assert Map.has_key?(adapted, :raw_preview)
      assert adapted.raw_preview =~ "Hello from agent"
    end

    test "adapt_acpx_event sets raw_event_at and raw_preview for tool_call" do
      data = %{"toolName" => "Read", "input" => %{"file_path" => "/workspace/test.txt"}}
      adapted = AcpxSession.__testing__().adapt_acpx_event.(:tool_call, data)

      assert adapted.raw_event_at != nil
      assert adapted.raw_preview != nil
    end

    test "adapt_acpx_event sets raw_event_at and raw_preview for usage_update" do
      data = %{"inputTokens" => 100, "outputTokens" => 50, "totalTokens" => 150}
      adapted = AcpxSession.__testing__().adapt_acpx_event.(:usage_update, data)

      assert adapted.raw_event_at != nil
      assert adapted.raw_preview != nil
    end

    test "adapt_acpx_event sets raw_event_at and raw_preview for turn_completed" do
      data = %{
        "status" => "success",
        "stopReason" => "end_turn",
        "usage" => %{"inputTokens" => 100, "outputTokens" => 50, "totalTokens" => 150}
      }
      adapted = AcpxSession.__testing__().adapt_acpx_event.(:result, data)

      assert adapted.raw_event_at != nil
      assert adapted.raw_preview != nil
    end

    test "adapt_acpx_event sets raw_event_at and raw_preview for error" do
      data = %{"message" => "Something went wrong"}
      adapted = AcpxSession.__testing__().adapt_acpx_event.(:error, data)

      assert adapted.raw_event_at != nil
      assert adapted.raw_preview =~ "Something went wrong"
    end
  end

  describe "bounded preview truncation" do
    test "large payload is truncated in raw_preview" do
      huge_content = String.duplicate("A", 5000)
      data = %{"content" => huge_content}
      adapted = AcpxSession.__testing__().adapt_acpx_event.(:agent_message_chunk, data)

      assert adapted.raw_preview != nil
      assert byte_size(adapted.raw_preview) <= 2048
    end

    test "normal payload is not truncated" do
      data = %{"content" => "Short message"}
      adapted = AcpxSession.__testing__().adapt_acpx_event.(:agent_message_chunk, data)

      assert adapted.raw_preview =~ "Short message"
    end

    test "binary payload gets bounded preview" do
      adapted = AcpxSession.__testing__().adapt_acpx_event.(:agent_message_chunk, "plain text data")

      assert adapted.raw_preview =~ "plain text data"
    end

    test "nil payload gets nil preview" do
      adapted = AcpxSession.__testing__().adapt_acpx_event.(:agent_message_chunk, nil)

      assert adapted.raw_preview == nil
    end
  end

  describe "parser error surfacing" do
    test "collect_output sends parser_error event for malformed JSON" do
      recipient = self()
      issue_id = "TEST-1"

      malformed_line = "this is not json at all"

      AcpxSession.__testing__().send_parser_error.(recipient, issue_id, :invalid_json, malformed_line)

      assert_received {:agent_worker_update, ^issue_id, update}
      assert update.event == :parser_error
      assert update.raw_event_at != nil
      assert update.raw_preview =~ "this is not json"
    end

    test "parser error event has bounded raw_preview" do
      recipient = self()
      issue_id = "TEST-2"

      huge_malformed = "not json " <> String.duplicate("X", 5000)
      AcpxSession.__testing__().send_parser_error.(recipient, issue_id, :invalid_json, huge_malformed)

      assert_received {:agent_worker_update, ^issue_id, update}
      assert byte_size(update.raw_preview) <= 300
    end
  end

  describe "orchestrator integrates ACPX observability events" do
    setup context do
      tmp_dir = Path.join(System.tmp_dir!(), "symphony-obs-orch-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      issue_id = context[:issue_id] || "OBS-1"

      {:ok, pid} = start_supervised({Orchestrator, [skip_poll: true]})

      running_entry = %{
        issue_id: issue_id,
        identifier: issue_id,
        state: :running,
        workspace_path: tmp_dir,
        started_at: DateTime.utc_now(),
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
        session_id: nil,
        session_name: nil,
        phase: "prompt_sent_turn_1",
        progress_source: "none",
        last_agent_event: nil,
        last_raw_event_at: nil,
        last_raw_preview: nil,
        last_agent_message: nil
      }

      :sys.replace_state(pid, fn state ->
        %{state | running: Map.put(state.running, issue_id, running_entry)}
      end)

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
      end)

      {:ok, pid: pid, tmp_dir: tmp_dir, issue_id: issue_id}
    end

    @tag issue_id: "OBS-10"
    test "agent_message event updates last_raw_event_at and last_raw_preview", %{pid: pid, issue_id: issue_id} do
      now = DateTime.utc_now()

      update = %{
        event: :agent_message,
        timestamp: now,
        payload: %{"content" => "I will analyze the code"},
        raw_event_at: now,
        raw_preview: "I will analyze the code"
      }

      send(pid, {:agent_worker_update, issue_id, update})

      state = :sys.get_state(pid, 5000)
      entry = Map.get(state.running, issue_id)

      assert entry != nil
      assert entry.last_raw_event_at != nil
      assert entry.last_raw_preview =~ "I will analyze the code"
      assert entry.progress_source == "raw_event"
    end

    @tag issue_id: "OBS-11"
    test "usage_update event updates token counts", %{pid: pid, issue_id: issue_id} do
      update = %{
        event: :usage_update,
        timestamp: DateTime.utc_now(),
        usage: %{input_tokens: 100, output_tokens: 50, total_tokens: 150},
        payload: %{},
        raw_event_at: DateTime.utc_now(),
        raw_preview: "usage: 150 tokens"
      }

      send(pid, {:agent_worker_update, issue_id, update})

      state = :sys.get_state(pid, 5000)
      entry = Map.get(state.running, issue_id)

      assert entry != nil
      assert entry.agent_total_tokens > 0
    end

    @tag issue_id: "OBS-12"
    test "parser_error event updates progress_source", %{pid: pid, issue_id: issue_id} do
      update = %{
        event: :parser_error,
        timestamp: DateTime.utc_now(),
        raw_event_at: DateTime.utc_now(),
        raw_preview: "malformed json line",
        payload: %{parse_error: "invalid_json"}
      }

      send(pid, {:agent_worker_update, issue_id, update})

      state = :sys.get_state(pid, 5000)
      entry = Map.get(state.running, issue_id)

      assert entry != nil
      assert entry.last_raw_event_at != nil
      assert entry.last_raw_preview =~ "malformed json"
    end

    @tag issue_id: "OBS-13"
    test "consecutive parser errors escalate progress_source to parser_error", %{pid: pid, issue_id: issue_id} do
      for _i <- 1..5 do
        update = %{
          event: :parser_error,
          timestamp: DateTime.utc_now(),
          raw_event_at: DateTime.utc_now(),
          raw_preview: "parse error",
          payload: %{parse_error: "invalid_json"}
        }

        send(pid, {:agent_worker_update, issue_id, update})
        Process.sleep(10)
      end

      state = :sys.get_state(pid, 5000)
      entry = Map.get(state.running, issue_id)

      assert entry != nil
      assert entry.progress_source == "parser_error"
    end

    @tag issue_id: "OBS-14"
    test "PRI-151 regression: process alive but no events shows stalled_no_events", %{pid: pid, issue_id: issue_id} do
      started_at = DateTime.add(DateTime.utc_now(), -120, :second)

      :sys.replace_state(pid, fn state ->
        entry = Map.get(state.running, issue_id)
        updated_entry = Map.merge(entry, %{
          started_at: started_at,
          last_process_seen_at: DateTime.utc_now(),
          last_raw_event_at: nil,
          progress_source: "process_alive"
        })
        %{state | running: Map.put(state.running, issue_id, updated_entry)}
      end)

      state = :sys.replace_state(pid, fn state ->
        entry = Map.get(state.running, issue_id)
        updated_entry = Orchestrator.reconcile_progress_source(entry)
        %{state | running: Map.put(state.running, issue_id, updated_entry)}
      end)

      entry = Map.get(state.running, issue_id)
      assert entry.progress_source == "stalled_no_events"
    end
  end
end

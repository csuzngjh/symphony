defmodule SymphonyElixir.ACPXSessionStreamTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRunner.AcpxSessionStream

  describe "real ACPX session stream shape parser" do
    setup do
      dir = System.tmp_dir!()
      record_id = "test-record-#{:erlang.unique_integer([:positive])}"
      path = Path.join(dir, "#{record_id}.stream.ndjson")

      on_exit(fn ->
        File.rm(path)
      end)

      %{dir: dir, record_id: record_id, path: path}
    end

    test "parses real ACPX session stream events", %{dir: dir, record_id: record_id, path: path} do
      lines = [
        ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"abc","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Reading docs"}}}}),
        ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"abc","update":{"sessionUpdate":"tool_call_update","title":"Read docs/runbooks/runtime-v2-production-runbook.md","kind":"read","locations":[{"path":"d:\\\\code\\\\principles-workspaces\\\\PRI-151\\\\docs\\\\runbooks\\\\runtime-v2-production-runbook.md","line":1}]}}}),
        ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"abc","update":{"sessionUpdate":"usage_update","used":123,"size":200000}}})
      ]

      File.write!(path, Enum.join(lines, "\n") <> "\n")

      progress = AcpxSessionStream.read_progress(record_id, session_root: dir)

      assert progress.latest_event_at != nil
      assert progress.latest_preview != nil
      assert progress.latest_message =~ "Reading docs"
      assert progress.token_usage.total_tokens > 0
      assert progress.latest_tool_preview =~ "tool_update"
      assert progress.stream_exists == true
      assert progress.events_parsed == 3
    end

    test "computes stream path from acpx_record_id", %{dir: dir, record_id: record_id} do
      path = AcpxSessionStream.stream_path_for_record(record_id, session_root: dir)
      assert path == Path.join(dir, "#{record_id}.stream.ndjson")
    end

    test "incremental reading skips already-read bytes", %{dir: dir, record_id: record_id, path: path} do
      line1 = ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"abc","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"First"}}}})
      line2 = ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"abc","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Second"}}}})

      File.write!(path, line1 <> "\n" <> line2 <> "\n")

      progress1 = AcpxSessionStream.read_progress(record_id, session_root: dir, bytes_offset: 0)
      assert progress1.latest_message =~ "Second"
      assert progress1.events_parsed == 2

      offset = progress1.bytes_read
      assert offset > 0

      line3 = ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"abc","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Third"}}}})
      File.write!(path, line1 <> "\n" <> line2 <> "\n" <> line3 <> "\n")

      progress2 = AcpxSessionStream.read_progress(record_id, session_root: dir, bytes_offset: offset)

      assert progress2.latest_message =~ "Third"
      assert progress2.events_parsed >= 1
    end
  end

  describe "large stream truncation" do
    test "large event text is truncated in preview" do
      huge_text = String.duplicate("A", 5000)
      lines = [
        ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"abc","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"#{huge_text}"}}}})
      ]

      progress = AcpxSessionStream.parse_stream_lines(lines, path: "test")

      assert progress.latest_preview != nil
      assert byte_size(progress.latest_preview) <= 2048
      assert progress.latest_message != nil
    end
  end

  describe "malformed ndjson line" do
    test "records parser error but continues processing" do
      lines = [
        "this is not valid json",
        ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"abc","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Still works"}}}})
      ]

      progress = AcpxSessionStream.parse_stream_lines(lines, path: "test")

      assert progress.parser_errors == 1
      assert progress.latest_message =~ "Still works"
      assert progress.latest_event_at != nil
      assert progress.events_parsed == 1
    end

    test "multiple malformed lines are counted" do
      lines = [
        "bad line 1",
        "bad line 2",
        "bad line 3"
      ]

      progress = AcpxSessionStream.parse_stream_lines(lines, path: "test")

      assert progress.parser_errors == 3
      assert progress.events_parsed == 0
      assert progress.latest_event_at == nil
    end
  end

  describe "no stream file" do
    test "returns empty progress when stream file does not exist" do
      dir = System.tmp_dir!()
      record_id = "nonexistent-#{:erlang.unique_integer([:positive])}"

      progress = AcpxSessionStream.read_progress(record_id, session_root: dir)

      assert progress.stream_exists == false
      assert progress.latest_event_at == nil
      assert progress.latest_message == nil
      assert progress.token_usage.total_tokens == 0
    end
  end

  describe "parse_stream_lines with real ACPX shapes" do
    test "tool_call_update with locations produces tool preview" do
      lines = [
        ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"abc","update":{"sessionUpdate":"tool_call_update","title":"Read docs/runbooks/runtime-v2-production-runbook.md","kind":"read","locations":[{"path":"d:\\\\code\\\\principles-workspaces\\\\PRI-151\\\\docs\\\\runbooks\\\\runtime-v2-production-runbook.md","line":1}]}}})
      ]

      progress = AcpxSessionStream.parse_stream_lines(lines, path: "test")

      assert progress.latest_tool_preview =~ "Read docs/runbooks"
      assert progress.latest_preview =~ "tool_update"
    end

    test "usage_update extracts token counts" do
      lines = [
        ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"abc","update":{"sessionUpdate":"usage_update","used":500,"size":200000,"inputTokens":100,"outputTokens":50,"totalTokens":150}}})
      ]

      progress = AcpxSessionStream.parse_stream_lines(lines, path: "test")

      assert progress.token_usage.input_tokens == 100
      assert progress.token_usage.output_tokens == 50
      assert progress.token_usage.total_tokens == 150
    end

    test "result event extracts usage from nested usage field" do
      lines = [
        ~s({"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn","usage":{"inputTokens":200,"outputTokens":100,"totalTokens":300}}})
      ]

      progress = AcpxSessionStream.parse_stream_lines(lines, path: "test")

      assert progress.token_usage.input_tokens == 200
      assert progress.token_usage.total_tokens == 300
    end

    test "empty lines are skipped" do
      lines = [
        "",
        ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"abc","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello"}}}}),
        "",
        ""
      ]

      progress = AcpxSessionStream.parse_stream_lines(lines, path: "test")

      assert progress.parser_errors == 0
      assert progress.events_parsed == 1
      assert progress.latest_message =~ "Hello"
    end
  end
end

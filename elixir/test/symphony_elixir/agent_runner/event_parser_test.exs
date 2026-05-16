defmodule SymphonyElixir.AgentRunner.EventParserTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRunner.EventParser

  describe "parse/1" do
    test "parses session/update notification with agent_thought_chunk" do
      line =
        ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_thought_chunk","content":{"text":"thinking..."}}}})

      assert {:ok, %{type: :agent_thought_chunk, data: data}} = EventParser.parse(line)
      assert data["sessionId"] == "s1"
      assert data["sessionUpdate"] == "agent_thought_chunk"
    end

    test "parses session/update notification with agent_message_chunk" do
      line =
        ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"text":"hello"}}}})

      assert {:ok, %{type: :agent_message_chunk}} = EventParser.parse(line)
    end

    test "parses session/update notification with tool_call" do
      line =
        ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolName":"bash"}}})

      assert {:ok, %{type: :tool_call}} = EventParser.parse(line)
    end

    test "parses session/update notification with tool_result" do
      line =
        ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_result","result":"ok"}}})

      assert {:ok, %{type: :tool_result}} = EventParser.parse(line)
    end

    test "parses session/update notification with usage_update" do
      line =
        ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"usage_update","tokens":100}}})

      assert {:ok, %{type: :usage_update}} = EventParser.parse(line)
    end

    test "parses session/update notification with session lifecycle" do
      line =
        ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"session/new"}}})

      assert {:ok, %{type: :session_update}} = EventParser.parse(line)
    end

    test "parses non-session method notification" do
      line =
        ~s({"jsonrpc":"2.0","method":"agent/thought_chunk","params":{"content":"thinking..."}})

      assert {:ok, %{type: :agent_thought_chunk}} = EventParser.parse(line)
    end

    test "parses result message" do
      line =
        ~s({"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn","usage":{}}})

      assert {:ok, %{type: :result, data: data}} = EventParser.parse(line)
      assert data["stopReason"] == "end_turn"
    end

    test "parses error message" do
      line =
        ~s({"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"invalid request"}})

      assert {:ok, %{type: :error, data: data}} = EventParser.parse(line)
      assert data["code"] == -32_600
    end

    test "returns error for empty line" do
      assert {:error, :empty_line} = EventParser.parse("")
      assert {:error, :empty_line} = EventParser.parse("   ")
    end

    test "returns error for non-JSON line" do
      assert {:error, {:non_json_line, "plain text"}} = EventParser.parse("plain text")
    end

    test "returns :unknown for valid JSON without jsonrpc field" do
      line = ~s({"message": "hello", "value": 42})
      assert {:ok, %{type: :unknown}} = EventParser.parse(line)
    end

    test "returns error for JSON array (not starting with {)" do
      assert {:error, {:non_json_line, "[1, 2, 3]"}} = EventParser.parse(~s([1, 2, 3]))
    end

    test "returns error for non-string input" do
      assert {:error, :not_string} = EventParser.parse(123)
      assert {:error, :not_string} = EventParser.parse(nil)
    end

    test "trims whitespace before parsing" do
      line =
        ~s(  {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk"}}}  )

      assert {:ok, %{type: :agent_message_chunk}} = EventParser.parse(line)
    end
  end

  describe "parse_output/1" do
    test "parses multi-line NDJSON output" do
      output =
        ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_thought_chunk"}}}\n) <>
          ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk"}}}\n) <>
          ~s({"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}})

      events = EventParser.parse_output(output)
      assert length(events) == 3
      assert Enum.map(events, & &1.type) == [:agent_thought_chunk, :agent_message_chunk, :result]
    end

    test "filters out error lines" do
      output =
        "not json\n" <>
          ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_thought_chunk"}}})

      events = EventParser.parse_output(output)
      assert length(events) == 1
    end
  end

  describe "extract_result/1" do
    test "extracts stop_reason and usage from :result events" do
      events = [
        %{type: :agent_thought_chunk, data: %{"content" => %{"text" => "thinking..."}}},
        %{type: :result, data: %{"stopReason" => "end_turn", "usage" => %{"tokens" => 100}}}
      ]

      result = EventParser.extract_result(events)
      assert result.stop_reason == "end_turn"
      assert result.usage == %{"tokens" => 100}
      assert result.status == "completed"
    end

    test "collects output from agent_message_chunk and agent_thought_chunk" do
      events = [
        %{type: :agent_thought_chunk, data: %{"content" => %{"text" => "Thinking"}}},
        %{type: :agent_message_chunk, data: %{"content" => %{"text" => "Hello"}}}
      ]

      result = EventParser.extract_result(events)
      assert result.output == "ThinkingHello"
    end

    test "returns events map when no :result event exists" do
      events = [%{type: :agent_thought_chunk, data: %{"content" => %{"text" => "thinking"}}}]
      assert %{status: "completed", events: ^events} = EventParser.extract_result(events)
    end

    test "prefers usage_update events over result usage" do
      result_event = %{type: :result, data: %{"stopReason" => "end_turn", "usage" => %{"from_result" => true}}}
      usage_event = %{type: :usage_update, data: %{"from_update" => true}}
      result = EventParser.extract_result([result_event, usage_event])
      assert result.usage == %{"from_update" => true}
    end

    test "handles empty events list" do
      assert %{status: "completed", events: []} = EventParser.extract_result([])
    end

    test "collects output from flat string content (fake ACPX format)" do
      events = [
        %{type: :agent_thought_chunk, data: %{"content" => "thinking flat"}},
        %{type: :agent_message_chunk, data: %{"content" => "hello flat"}}
      ]

      result = EventParser.extract_result(events)
      assert result.output == "thinking flathello flat"
    end

    test "collects output from update wrapper format" do
      events = [
        %{type: :agent_message_chunk, data: %{"update" => %{"content" => "wrapped content"}}}
      ]

      result = EventParser.extract_result(events)
      assert result.output == "wrapped content"
    end

    test "does not crash when update key is nil" do
      events = [
        %{type: :agent_message_chunk, data: %{"update" => nil}}
      ]

      result = EventParser.extract_result(events)
      assert result.output == ""
    end

    test "returns empty string when no content field exists" do
      events = [
        %{type: :agent_message_chunk, data: %{"other" => "irrelevant"}}
      ]

      result = EventParser.extract_result(events)
      assert result.output == ""
    end

    test "handles mixed nested and flat content formats" do
      events = [
        %{type: :agent_thought_chunk, data: %{"content" => %{"text" => "nested"}}},
        %{type: :agent_message_chunk, data: %{"content" => "flat"}},
        %{type: :agent_message_chunk, data: %{"update" => %{"content" => "wrapped"}}}
      ]

      result = EventParser.extract_result(events)
      assert result.output == "nestedflatwrapped"
    end
  end
end

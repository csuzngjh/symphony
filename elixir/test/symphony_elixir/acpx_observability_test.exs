defmodule SymphonyElixir.ACPXObservabilityTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRunner.AcpxSession

  describe "ACPX event stream observability" do
    test "adapt_acpx_event sets raw_event_at and raw_preview for agent_message_chunk" do
      data = %{"content" => "Hello from agent"}
      adapted = AcpxSession.__testing__().adapt_acpx_event.(:agent_message_chunk, data)

      assert is_struct(adapted.raw_event_at, DateTime)
      assert adapted.raw_preview =~ "Hello from agent"
    end

    test "adapt_acpx_event sets raw_event_at and raw_preview for tool_call" do
      data = %{"toolName" => "Read", "input" => %{"file_path" => "/workspace/test.txt"}}
      adapted = AcpxSession.__testing__().adapt_acpx_event.(:tool_call, data)

      assert is_struct(adapted.raw_event_at, DateTime)
      assert adapted.raw_preview != nil
    end

    test "adapt_acpx_event sets raw_event_at and raw_preview for usage_update" do
      data = %{"inputTokens" => 100, "outputTokens" => 50, "totalTokens" => 150}
      adapted = AcpxSession.__testing__().adapt_acpx_event.(:usage_update, data)

      assert is_struct(adapted.raw_event_at, DateTime)
      assert adapted.raw_preview != nil
    end

    test "adapt_acpx_event sets raw_event_at and raw_preview for turn_completed" do
      data = %{
        "status" => "success",
        "stopReason" => "end_turn",
        "usage" => %{"inputTokens" => 100, "outputTokens" => 50, "totalTokens" => 150}
      }
      adapted = AcpxSession.__testing__().adapt_acpx_event.(:result, data)

      assert is_struct(adapted.raw_event_at, DateTime)
      assert adapted.raw_preview != nil
    end

    test "adapt_acpx_event sets raw_event_at and raw_preview for error" do
      data = %{"message" => "Something went wrong"}
      adapted = AcpxSession.__testing__().adapt_acpx_event.(:error, data)

      assert is_struct(adapted.raw_event_at, DateTime)
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
      assert is_struct(update.raw_event_at, DateTime)
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
end

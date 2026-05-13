defmodule SymphonyElixir.AgentRunner.EventParserTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRunner.EventParser

  describe "parse/1" do
    test "parses valid JSON with type and data fields" do
      line = ~s({"type": "message", "data": {"text": "hello"}})
      assert {:ok, %{type: :message, data: %{"text" => "hello"}}} = EventParser.parse(line)
    end

    test "parses valid JSON with type but no data key" do
      line = ~s({"type": "step", "content": "thinking", "timestamp": 123})
      assert {:ok, %{type: :step, data: data}} = EventParser.parse(line)
      assert data == %{"content" => "thinking", "timestamp" => 123}
    end

    test "returns error for valid JSON without type field" do
      line = ~s({"message": "hello", "value": 42})
      assert {:error, :missing_type_field} = EventParser.parse(line)
    end

    test "returns error for non-JSON line" do
      assert {:error, :not_json} = EventParser.parse("plain text")
      assert {:error, :not_json} = EventParser.parse("[1, 2, 3]")
    end

    test "returns error for non-string input" do
      assert {:error, :not_string} = EventParser.parse(123)
      assert {:error, :not_string} = EventParser.parse(nil)
    end

    test "trims whitespace before parsing" do
      line = ~s(  {"type": "message", "data": {"text": "hi"}}  )
      assert {:ok, %{type: :message}} = EventParser.parse(line)
    end

    test "converts type string to atom" do
      line = ~s({"type": "my_custom_event", "data": {}})
      assert {:ok, %{type: :my_custom_event}} = EventParser.parse(line)
    end
  end

  describe "extract_result/1" do
    test "returns result map when a :result event exists" do
      events = [
        %{type: :step, data: %{"content" => "thinking"}},
        %{type: :result, data: %{"answer" => 42}}
      ]
      assert %{status: "completed", result: %{"answer" => 42}, usage: %{}} = EventParser.extract_result(events)
    end

    test "returns events map when no :result event exists" do
      events = [%{type: :step, data: %{"content" => "thinking"}}]
      assert %{status: "completed", events: ^events} = EventParser.extract_result(events)
    end

    test "extracts usage from result event data" do
      events = [%{type: :result, data: %{"answer" => "done", "usage" => %{"tokens" => 100}}}]
      assert %{usage: %{"tokens" => 100}} = EventParser.extract_result(events)
    end

    test "handles empty events list" do
      assert %{status: "completed", events: []} = EventParser.extract_result([])
    end
  end
end
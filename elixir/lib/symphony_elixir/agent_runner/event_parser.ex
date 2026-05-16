defmodule SymphonyElixir.AgentRunner.EventParser do
  @moduledoc """
  Parse acpx NDJSON output to structured events.

  acpx --format json outputs raw ACP JSON-RPC 2.0 messages:
  ```
  {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"...","update":{"sessionUpdate":"agent_thought_chunk",...}}}
  {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"...","update":{"sessionUpdate":"tool_call",...}}}
  {"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn","usage":{...}}}
  {"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"..."}}
  ```

  The session/update notification wraps all agent activity in params.update.sessionUpdate.
  We extract the specific event type from that field.

  Event types:
  - :session_update - Session lifecycle (session/new confirmation)
  - :agent_thought_chunk - Agent thinking/reasoning
  - :agent_message_chunk - Agent response content
  - :tool_call - Tool invocation started
  - :tool_call_update - Tool invocation progress
  - :tool_result - Tool execution result (via session/update with sessionUpdate=tool_result)
  - :usage_update - Token/usage information
  - :result - Final prompt result with stopReason
  - :error - Error condition
  """

  @type event_type ::
          :session_update
          | :agent_thought_chunk
          | :agent_message_chunk
          | :tool_call
          | :tool_call_update
          | :tool_result
          | :usage_update
          | :result
          | :error
          | :unknown

  @type event :: %{
          type: event_type(),
          data: map(),
          raw: String.t()
        }

  @spec parse(String.t()) :: {:ok, event()} | {:error, term()}
  def parse(line) when is_binary(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        {:error, :empty_line}

      not String.starts_with?(trimmed, "{") ->
        {:error, {:non_json_line, trimmed}}

      true ->
        case Jason.decode(trimmed) do
          {:ok, %{"jsonrpc" => "2.0", "method" => "session/update", "params" => params}} ->
            {:ok, parse_session_update(params, trimmed)}

          {:ok, %{"jsonrpc" => "2.0", "method" => method, "params" => params}} ->
            {:ok, %{type: parse_method(method), data: params, raw: trimmed}}

          {:ok, %{"jsonrpc" => "2.0", "result" => result, "id" => _id}} ->
            {:ok, %{type: :result, data: result, raw: trimmed}}

          {:ok, %{"jsonrpc" => "2.0", "error" => error}} ->
            {:ok, %{type: :error, data: error, raw: trimmed}}

          {:ok, payload} ->
            {:ok, %{type: :unknown, data: payload, raw: trimmed}}

          {:error, reason} ->
            {:error, {:parse_error, reason, trimmed}}
        end
    end
  end

  def parse(_line), do: {:error, :not_string}

  defp parse_session_update(params, raw) do
    update = Map.get(params, "update") || %{}
    session_update_type = Map.get(update, "sessionUpdate")

    specific_type = classify_session_update(session_update_type)

    %{type: specific_type, data: Map.merge(params, update), raw: raw}
  end

  defp classify_session_update("agent_thought_chunk"), do: :agent_thought_chunk
  defp classify_session_update("agent_message_chunk"), do: :agent_message_chunk
  defp classify_session_update("tool_call"), do: :tool_call
  defp classify_session_update("tool_call_update"), do: :tool_call_update
  defp classify_session_update("tool_result"), do: :tool_result
  defp classify_session_update("usage_update"), do: :usage_update
  defp classify_session_update("session/new"), do: :session_update
  defp classify_session_update("session/cancel"), do: :session_update
  defp classify_session_update("session/close"), do: :session_update
  defp classify_session_update(_), do: :session_update

  defp parse_method("session/update"), do: :session_update

  defp parse_method("agent/thought_chunk") do
    :agent_thought_chunk
  end

  defp parse_method("agent/message_chunk") do
    :agent_message_chunk
  end

  defp parse_method("tools/call") do
    :tool_call
  end

  defp parse_method("tools/call/update") do
    :tool_call_update
  end

  defp parse_method("tools/result") do
    :tool_result
  end

  defp parse_method("usage/update") do
    :usage_update
  end

  defp parse_method(_), do: :unknown

  @spec parse_output(String.t()) :: [event()]
  def parse_output(output) do
    output
    |> String.split("\n")
    |> Enum.map(&parse/1)
    |> Enum.reject(fn
      {:error, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {:ok, event} -> event end)
  end

  @spec extract_result([event()]) :: %{
          status: String.t(),
          stop_reason: String.t() | nil,
          output: String.t(),
          usage: map() | nil,
          events: [event()]
        }
  def extract_result(events) do
    result_events = Enum.filter(events, fn e -> e.type == :result end)

    output_parts =
      events
      |> Enum.filter(fn e -> e.type in [:agent_message_chunk, :agent_thought_chunk] end)
      |> Enum.map(fn e ->
        cond do
          is_map(e.data["content"]) -> e.data["content"]["text"] || ""
          is_binary(e.data["content"]) -> e.data["content"]
          is_map(e.data["update"]) and is_binary(e.data["update"]["content"]) -> e.data["update"]["content"]
          true -> ""
        end
      end)
      |> Enum.join("")

    usage =
      events
      |> Enum.filter(fn e -> e.type == :usage_update end)
      |> List.last()
      |> case do
        nil -> nil
        event -> event.data
      end

    case result_events do
      [] ->
        %{
          status: "completed",
          stop_reason: nil,
          output: output_parts,
          usage: usage,
          events: events
        }

      [_ | _] ->
        last_result = List.last(result_events)

        %{
          status: "completed",
          stop_reason: last_result.data["stopReason"],
          output: output_parts,
          usage: usage || last_result.data["usage"],
          events: events
        }
    end
  end
end

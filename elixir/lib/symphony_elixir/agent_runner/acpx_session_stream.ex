defmodule SymphonyElixir.AgentRunner.AcpxSessionStream do
  @moduledoc """
  Reads ACPX session stream NDJSON files to extract progress observability.

  ACPX writes real-time events to:
    %USERPROFILE%\\.acpx\\sessions\\<acpxRecordId>.stream.ndjson

  This module provides a fallback when stdout doesn't produce raw events
  (e.g., when --suppress-reads is active).
  """

  require Logger

  alias SymphonyElixir.AgentRunner.EventParser

  @max_read_bytes 2_097_152
  @max_lines_per_read 500
  @max_preview_bytes 2048

  @type progress :: %{
          latest_event_at: DateTime.t() | nil,
          latest_preview: String.t() | nil,
          latest_message: String.t() | nil,
          latest_tool_preview: String.t() | nil,
          latest_error: map() | nil,
          token_usage: map(),
          parser_errors: non_neg_integer(),
          stream_path: String.t(),
          stream_exists: boolean(),
          stream_last_modified: DateTime.t() | nil,
          bytes_read: non_neg_integer(),
          events_parsed: non_neg_integer()
        }

  @spec stream_path_for_record(String.t(), keyword()) :: String.t()
  def stream_path_for_record(acpx_record_id, opts \\ []) do
    session_root = Keyword.get(opts, :session_root) || default_session_root()
    Path.join([session_root, "#{acpx_record_id}.stream.ndjson"])
  end

  @spec read_progress(String.t(), keyword()) :: progress()
  def read_progress(acpx_record_id, opts) when is_binary(acpx_record_id) do
    path = stream_path_for_record(acpx_record_id, opts)
    read_progress_from_path(path, opts)
  end

  @spec read_progress_from_path(String.t(), keyword()) :: progress()
  def read_progress_from_path(path, opts) when is_binary(path) do
    bytes_offset = Keyword.get(opts, :bytes_offset, 0)

    case File.stat(path) do
      {:ok, %File.Stat{size: size, mtime: mtime}} ->
        bytes_to_read = min(size - bytes_offset, @max_read_bytes)

        if bytes_to_read <= 0 do
          empty_progress(path, true, mtime, size)
        else
          case :file.open(path, [:read, :binary, :raw]) do
            {:ok, file} ->
              try do
                case :file.position(file, bytes_offset) do
                  {:ok, _} ->
                    data = read_bounded(file, bytes_to_read)
                    actual_bytes_read = byte_size(data)
                    lines = String.split(data, "\n", trim: false)

                    progress =
                      lines
                      |> Enum.take(@max_lines_per_read)
                      |> Enum.reduce(empty_progress(path, true, mtime, bytes_offset + actual_bytes_read), fn line, acc ->
                        parse_and_merge_line(line, acc)
                      end)

                    progress

                  {:error, reason} ->
                    Logger.debug("Cannot seek stream file #{path} to offset #{bytes_offset}: #{inspect(reason)}")
                    empty_progress(path, true, mtime, 0)
                end
              after
                :file.close(file)
              end

            {:error, reason} ->
              Logger.debug("Cannot open stream file #{path}: #{inspect(reason)}")
              empty_progress(path, true, mtime, bytes_offset)
          end
        end

      {:error, _reason} ->
        empty_progress(path, false, nil, bytes_offset)
    end
  end

  @spec parse_stream_lines([String.t()], keyword()) :: progress()
  def parse_stream_lines(lines, opts \\ []) do
    Enum.reduce(lines, empty_progress(Keyword.get(opts, :path, ""), false, nil, 0), fn line, acc ->
      parse_and_merge_line(line, acc)
    end)
  end

  defp parse_and_merge_line(line, acc) do
    trimmed = String.trim(line)

    if trimmed == "" do
      acc
    else
      case EventParser.parse(trimmed) do
        {:ok, %{type: type, data: data}} ->
          acc
          |> merge_event(type, data)
          |> Map.update!(:events_parsed, &(&1 + 1))

        {:error, _reason} ->
          Map.update!(acc, :parser_errors, &(&1 + 1))
      end
    end
  end

  defp merge_event(acc, :agent_message_chunk, data) do
    text = extract_text(data)
    preview = bounded_preview(text)

    acc
    |> Map.put(:latest_error, nil)
    |> Map.put(:latest_event_at, DateTime.utc_now())
    |> Map.put(:latest_preview, preview || acc.latest_preview)
    |> Map.put(:latest_message, text || acc.latest_message)
  end

  defp merge_event(acc, :agent_thought_chunk, data) do
    text = extract_text(data)
    preview = bounded_preview(text)

    acc
    |> Map.put(:latest_error, nil)
    |> Map.put(:latest_event_at, DateTime.utc_now())
    |> Map.put(:latest_preview, preview || acc.latest_preview)
  end

  defp merge_event(acc, :tool_call, data) do
    title = data["title"] || data["toolName"] || inspect(data)
    preview = bounded_preview("tool_call: #{title}")

    acc
    |> Map.put(:latest_error, nil)
    |> Map.put(:latest_event_at, DateTime.utc_now())
    |> Map.put(:latest_preview, preview || acc.latest_preview)
    |> Map.put(:latest_tool_preview, preview || acc.latest_tool_preview)
  end

  defp merge_event(acc, :tool_call_update, data) do
    title = data["title"] || data["toolName"] || ""
    kind = data["kind"] || ""
    locations = data["locations"] || []
    loc_preview = if locations != [], do: " #{inspect(hd(locations))}", else: ""
    preview = bounded_preview("tool_update(#{kind}): #{title}#{loc_preview}")

    acc
    |> Map.put(:latest_error, nil)
    |> Map.put(:latest_event_at, DateTime.utc_now())
    |> Map.put(:latest_preview, preview || acc.latest_preview)
    |> Map.put(:latest_tool_preview, preview || acc.latest_tool_preview)
  end

  defp merge_event(acc, :tool_result, data) do
    preview = bounded_preview(inspect(data))

    acc
    |> Map.put(:latest_error, nil)
    |> Map.put(:latest_event_at, DateTime.utc_now())
    |> Map.put(:latest_preview, preview || acc.latest_preview)
  end

  defp merge_event(acc, :usage_update, data) do
    usage = extract_usage(data)

    acc
    |> Map.put(:latest_error, nil)
    |> Map.put(:latest_event_at, DateTime.utc_now())
    |> Map.put(:token_usage, merge_token_usage(acc.token_usage, usage))
    |> Map.put(:latest_preview, usage_preview(usage) || acc.latest_preview)
  end

  defp merge_event(acc, :result, data) do
    usage = extract_usage(data["usage"] || %{})

    acc
    |> Map.put(:latest_error, nil)
    |> Map.put(:latest_event_at, DateTime.utc_now())
    |> Map.put(:token_usage, merge_token_usage(acc.token_usage, usage))
  end

  defp merge_event(acc, :session_update, _data) do
    acc
    |> Map.put(:latest_error, nil)
    |> Map.put(:latest_event_at, DateTime.utc_now())
  end

  defp merge_event(acc, :error, data) do
    preview = bounded_preview(data["message"] || inspect(data))

    if benign_session_load_miss?(data) do
      acc
      |> Map.put(:latest_event_at, DateTime.utc_now())
      |> Map.put(:latest_preview, preview || acc.latest_preview)
    else
      acc
      |> Map.put(:latest_event_at, DateTime.utc_now())
      |> Map.put(:latest_preview, preview || acc.latest_preview)
      |> Map.put(:latest_error, data)
    end
  end

  defp merge_event(acc, _type, _data) do
    acc
    |> Map.put(:latest_error, nil)
  end

  defp benign_session_load_miss?(data) when is_map(data) do
    message = data["message"] |> to_string()
    code = data["code"]
    code == -32002 and String.starts_with?(message, "Resource not found:")
  end

  defp benign_session_load_miss?(_data), do: false

  defp extract_text(data) do
    cond do
      is_map(data["content"]) -> data["content"]["text"]
      is_binary(data["content"]) -> data["content"]
      is_map(data["update"]) and is_binary(data["update"]["content"]) -> data["update"]["content"]
      is_map(data["update"]) and is_map(data["update"]["content"]) -> data["update"]["content"]["text"]
      true -> nil
    end
  end

  defp bounded_preview(nil), do: nil
  defp bounded_preview(text) when is_binary(text) do
    if byte_size(text) <= @max_preview_bytes do
      text
    else
      String.slice(text, 0, div(@max_preview_bytes, 2) - 3) <> "..."
    end
  end
  defp bounded_preview(other), do: bounded_preview(to_string(other))

  defp extract_usage(usage) when is_map(usage) do
    total = usage["totalTokens"] || usage["total_tokens"] || usage["used"] || 0
    %{
      input_tokens: usage["inputTokens"] || usage["input_tokens"] || 0,
      output_tokens: usage["outputTokens"] || usage["output_tokens"] || 0,
      total_tokens: total,
      cached_read_tokens: usage["cachedReadTokens"] || 0,
      cached_write_tokens: usage["cachedWriteTokens"] || 0
    }
  end
  defp extract_usage(_), do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, cached_read_tokens: 0, cached_write_tokens: 0}

  defp usage_preview(usage) do
    if usage.total_tokens > 0 do
      "usage: #{usage.total_tokens} tokens"
    else
      nil
    end
  end

  defp merge_token_usage(existing, new) do
    %{
      input_tokens: max(existing.input_tokens, new.input_tokens),
      output_tokens: max(existing.output_tokens, new.output_tokens),
      total_tokens: max(existing.total_tokens, new.total_tokens),
      cached_read_tokens: max(existing.cached_read_tokens, new.cached_read_tokens),
      cached_write_tokens: max(existing.cached_write_tokens, new.cached_write_tokens)
    }
  end

  defp empty_progress(path, exists, mtime, bytes_offset) do
    %{
      latest_event_at: nil,
      latest_preview: nil,
      latest_message: nil,
      latest_tool_preview: nil,
      latest_error: nil,
      token_usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, cached_read_tokens: 0, cached_write_tokens: 0},
      parser_errors: 0,
      stream_path: path,
      stream_exists: exists,
      stream_last_modified: erlang_mtime_to_datetime(mtime),
      bytes_read: bytes_offset,
      events_parsed: 0
    }
  end

  defp default_session_root do
    Path.join([System.user_home(), ".acpx", "sessions"])
  end

  defp erlang_mtime_to_datetime({{year, month, day}, {hour, min, sec}}) do
    {:ok, dt} = NaiveDateTime.new(year, month, day, hour, min, sec)
    DateTime.from_naive!(dt, "Etc/UTC")
  end
  defp erlang_mtime_to_datetime(_), do: nil

  defp read_bounded(file, max_bytes) do
    case :file.read(file, max_bytes) do
      {:ok, data} -> data
      :eof -> ""
      {:error, reason} ->
        Logger.debug("Stream file read error: #{inspect(reason)}")
        ""
    end
  end

  @doc false
  def __testing__ do
    %{
      stream_path_for_record: &stream_path_for_record/2,
      read_progress_from_path: &read_progress_from_path/2,
      parse_stream_lines: &parse_stream_lines/2,
      extract_text: &extract_text/1,
      bounded_preview: &bounded_preview/1,
      extract_usage: &extract_usage/1
    }
  end
end

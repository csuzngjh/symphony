defmodule SymphonyElixir.OrchestratorProgressReconcileTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator

  describe "reconcile_progress_source" do
    test "escapes process_alive to stalled_no_events after grace period" do
      entry = %{
        issue_id: "ST-1",
        progress_source: "process_alive",
        started_at: DateTime.add(DateTime.utc_now(), -120, :second),
        last_process_seen_at: DateTime.add(DateTime.utc_now(), -10, :second),
        last_raw_event_at: nil
      }

      result = Orchestrator.reconcile_progress_source(entry)

      assert result.progress_source == "stalled_no_events"
    end

    test "keeps process_alive if within grace period" do
      entry = %{
        issue_id: "ST-2",
        progress_source: "process_alive",
        started_at: DateTime.add(DateTime.utc_now(), -30, :second),
        last_process_seen_at: DateTime.utc_now(),
        last_raw_event_at: nil
      }

      result = Orchestrator.reconcile_progress_source(entry)

      assert result.progress_source == "process_alive"
    end

    test "keeps raw_event when raw events exist" do
      entry = %{
        issue_id: "ST-3",
        progress_source: "raw_event",
        started_at: DateTime.add(DateTime.utc_now(), -120, :second),
        last_raw_event_at: DateTime.utc_now(),
        consecutive_parser_errors: 0
      }

      result = Orchestrator.reconcile_progress_source(entry)

      assert result.progress_source == "raw_event"
    end

    test "escalates to parser_error when consecutive errors exceed threshold" do
      entry = %{
        issue_id: "ST-4",
        progress_source: "raw_event",
        started_at: DateTime.utc_now(),
        last_raw_event_at: DateTime.utc_now(),
        consecutive_parser_errors: 5
      }

      result = Orchestrator.reconcile_progress_source(entry)

      assert result.progress_source == "parser_error"
    end

    test "does not change parser_error state" do
      entry = %{
        issue_id: "ST-5",
        progress_source: "parser_error",
        started_at: DateTime.utc_now(),
        last_raw_event_at: nil,
        consecutive_parser_errors: 4
      }

      result = Orchestrator.reconcile_progress_source(entry)

      assert result.progress_source == "parser_error"
    end

    test "does not change stalled_no_events state" do
      entry = %{
        issue_id: "ST-6",
        progress_source: "stalled_no_events",
        started_at: DateTime.add(DateTime.utc_now(), -300, :second),
        last_raw_event_at: nil
      }

      result = Orchestrator.reconcile_progress_source(entry)

      assert result.progress_source == "stalled_no_events"
    end

    test "keeps none when no activity" do
      entry = %{
        issue_id: "ST-7",
        progress_source: "none",
        started_at: DateTime.utc_now(),
        last_raw_event_at: nil,
        last_process_seen_at: nil
      }

      result = Orchestrator.reconcile_progress_source(entry)

      assert result.progress_source == "none"
    end

    test "keeps acpx_session_stream as terminal state" do
      entry = %{
        issue_id: "ST-8",
        progress_source: "acpx_session_stream",
        started_at: DateTime.utc_now(),
        last_raw_event_at: DateTime.utc_now(),
        consecutive_parser_errors: 0
      }

      result = Orchestrator.reconcile_progress_source(entry)

      assert result.progress_source == "acpx_session_stream"
    end

    test "escalates process_alive to stalled_no_events even with acpx_record_id when stream missing" do
      entry = %{
        issue_id: "ST-9",
        progress_source: "process_alive",
        started_at: DateTime.add(DateTime.utc_now(), -120, :second),
        last_process_seen_at: DateTime.add(DateTime.utc_now(), -10, :second),
        last_raw_event_at: nil,
        acpx_record_id: "some-record-id"
      }

      result = Orchestrator.reconcile_progress_source(entry)

      assert result.progress_source == "stalled_no_events"
    end
  end
end

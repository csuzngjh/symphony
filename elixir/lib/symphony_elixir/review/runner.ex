defmodule SymphonyElixir.Review.Runner do
  @moduledoc """
  Runs multi-dimensional code review against a workspace in parallel.

  Each of the 4 review dimensions runs independently via `Task.async_stream`,
  constrained by `config.review.max_concurrent` and `config.review.timeout_ms`.

  The runner is read-only: it does not modify workspace files, write to Linear,
  or integrate with the Orchestrator. It is manually callable only.
  """

  require Logger
  alias SymphonyElixir.Review.{Dimension, Result, PromptBuilder}

  @spec run(map(), String.t(), SymphonyElixir.Config.Schema.t(), keyword()) :: {:ok, [Result.t()]}
  def run(_issue, workspace_path, config, opts \\ []) do
    executor = Keyword.get(opts, :executor, SymphonyElixir.AgentRunner.AcpxSession)
    dimensions = Dimension.all()
    timeout_ms = config.review.timeout_ms
    max_concurrent = config.review.max_concurrent

    results =
      dimensions
      |> Task.async_stream(
        fn dim -> run_dimension(dim, workspace_path, executor, timeout_ms) end,
        max_concurrency: max_concurrent,
        timeout: timeout_ms,
        on_timeout: :kill_task
      )
      |> Stream.zip(dimensions)
      |> Enum.map(fn
        {{:ok, result}, _dim} ->
          result

        {{:exit, :timeout}, dim} ->
          Logger.warning("Review dimension #{dim.name} timed out after #{timeout_ms}ms")
          Result.timeout(dim.name)
      end)

    {:ok, results}
  end

  defp run_dimension(dim, workspace_path, executor, timeout_ms) do
    prompt = PromptBuilder.build(dim.name)

    Logger.info("Starting review dimension #{dim.name}")

    case executor.exec(workspace_path, prompt, timeout_ms) do
      {:ok, response} ->
        raw_text = normalize_response(response)

        case PromptBuilder.parse_response(raw_text) do
          {:ok, parsed} ->
            Result.success(
              dim.name,
              parsed.score,
              parsed.summary,
              parsed.details,
              parsed.business_summary
            )

          {:error, reason} ->
            Logger.warning("Failed to parse response for #{dim.name}: #{reason}")
            Result.failure(dim.name, reason)
        end

      {:error, reason} ->
        Logger.warning("Executor failed for #{dim.name}: #{inspect(reason)}")
        Result.failure(dim.name, inspect(reason))
    end
  end

  defp normalize_response(response) when is_binary(response), do: response
  defp normalize_response(response), do: inspect(response)
end
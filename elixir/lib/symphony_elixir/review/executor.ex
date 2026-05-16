defmodule SymphonyElixir.Review.Executor do
  @moduledoc false

  alias SymphonyElixir.AgentRunner.AcpxSession

  @spec exec(String.t(), String.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def exec(workspace_path, prompt, timeout_ms) do
    case AcpxSession.start_link(cwd: workspace_path) do
      {:ok, pid} ->
        try do
          AcpxSession.sessions_ensure(pid, "review", workspace_path)

          result =
            AcpxSession.exec(pid, prompt,
              timeout: timeout_ms,
              max_turns: 1,
              suppress_reads: true
            )

          case result do
            {:ok, response} -> {:ok, format_response(response)}
            {:error, reason} -> {:error, reason}
          end
        after
          AcpxSession.sessions_close(pid)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_response(%{output: output}) when is_binary(output), do: output
  defp format_response(%{text: text}) when is_binary(text), do: text
  defp format_response(response) when is_binary(response), do: response
  defp format_response(response), do: inspect(response)
end

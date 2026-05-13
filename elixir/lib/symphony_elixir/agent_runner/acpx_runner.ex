defmodule SymphonyElixir.AgentRunner.AcpxRunner do
  @moduledoc """
  Helper module for building acpx commands and parsing results.

  ACPX command grammar: acpx [global_options] <agent> [subcommand] [subcommand_options]
  Global options MUST appear before the agent subcommand.
  """

  @default_agent "claude"

  @spec build_exec_command(String.t(), String.t(), keyword()) :: [String.t()]
  def build_exec_command(agent \\ @default_agent, prompt \\ "", opts \\ []) do
    format = Keyword.get(opts, :format, "json")
    approve_all = Keyword.get(opts, :approve_all, true)
    cwd = Keyword.get(opts, :cwd, ".")

    args = ["--format", format, "--cwd", cwd]

    args =
      if approve_all do
        args ++ ["--approve-all"]
      else
        args
      end

    args = args ++ ["--non-interactive-permissions", "deny"]
    args = args ++ [agent, "exec"]

    args =
      if prompt != "" do
        args ++ [prompt]
      else
        args
      end

    args
  end

  @spec parse_result([map()]) :: {:ok, map()} | {:error, term()}
  def parse_result(events) when is_list(events) do
    result_events = Enum.filter(events, fn e -> e.type == :result end)

    case result_events do
      [] -> {:ok, %{status: "completed", events: events}}
      [_ | _] -> {:ok, %{status: "completed", result: List.last(result_events).data}}
    end
  end
end

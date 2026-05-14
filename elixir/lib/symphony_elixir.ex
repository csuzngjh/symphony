defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    require Logger

    Logger.info("SymphonyElixir.Application starting...")

    :ok = SymphonyElixir.LogFile.configure()
    Logger.info("LogFile configured")

    children = [
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
      SymphonyElixir.WorkflowStore,
      SymphonyElixir.Orchestrator,
      SymphonyElixir.HttpServer,
      SymphonyElixir.StatusDashboard
    ]

    Logger.info("Starting Symphony supervisor with #{length(children)} children")

    case Supervisor.start_link(
           children,
           strategy: :one_for_one,
           name: SymphonyElixir.Supervisor
         ) do
      {:ok, pid} ->
        Logger.info("Symphony supervisor started successfully pid=#{inspect(pid)}")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Symphony supervisor failed to start: #{inspect(reason)}")
        {:error, reason}

      other ->
        Logger.error("Symphony supervisor unexpected result: #{inspect(other)}")
        other
    end
  end

  @impl true
  def stop(_state) do
    require Logger
    Logger.info("SymphonyElixir.Application stopping...")
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end
end

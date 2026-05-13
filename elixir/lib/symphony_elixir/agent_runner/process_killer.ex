defmodule SymphonyElixir.AgentRunner.ProcessKiller do
  @moduledoc """
  Behaviour and default implementation for killing OS process trees.

  On Windows, uses `taskkill /T /F` to kill the entire process tree.
  On Unix, sends SIGTERM to the process group.

  The default implementation delegates to the configured `:process_killer`
  module, defaulting to `TaskkillProcessKiller` on Windows and
  `UnixProcessKiller` on other platforms.

  In tests, swap the module with a mock that records kill calls.
  """

  @callback kill_tree(os_pid :: pos_integer(), opts :: keyword()) :: :ok | {:error, term()}

  @doc """
  Kill the process tree rooted at `os_pid`.

  Returns `:ok` or `{:error, reason}`.  Idempotent — calling twice with
  the same pid is safe (second call may return `{:error, :no_such_process}`,
  which is treated as success).
  """
  @spec kill_tree(pos_integer(), keyword()) :: :ok | {:error, term()}
  def kill_tree(os_pid, opts \\ []) do
    impl().kill_tree(os_pid, opts)
  end

  @doc """
  Set a custom killer module (for tests).
  """
  @spec set_impl(module()) :: :ok
  def set_impl(module) when is_atom(module) do
    Application.put_env(:symphony_elixir, :process_killer_impl, module)
    :ok
  end

  @doc """
  Reset to the default implementation.
  """
  @spec reset_impl() :: :ok
  def reset_impl do
    Application.delete_env(:symphony_elixir, :process_killer_impl)
    :ok
  end

  defp impl do
    Application.get_env(:symphony_elixir, :process_killer_impl) ||
      default_impl()
  end

  defp default_impl do
    case :os.type() do
      {:win32, _} -> __MODULE__.WindowsTaskkill
      _ -> __MODULE__.UnixSigterm
    end
  end
end

defmodule SymphonyElixir.AgentRunner.ProcessKiller.WindowsTaskkill do
  @moduledoc """
  Kills a process tree on Windows via `taskkill /PID <pid> /T /F`.

  Access-denied errors are logged but still return `:ok` (the process
  may still be alive, but we treat permission-limited cleanup as
  best-effort).
  """

  require Logger
  @behaviour SymphonyElixir.AgentRunner.ProcessKiller

  @impl true
  def kill_tree(os_pid, _opts) when is_integer(os_pid) and os_pid > 0 do
    pid_str = Integer.to_string(os_pid)

    case System.cmd("taskkill", ["/PID", pid_str, "/T", "/F"],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, _status} ->
        if String.contains?(output, "not found") or
             String.contains?(output, "no running") or
             String.contains?(output, "不存在") do
          :ok
        else
          Logger.warning("ProcessKiller taskkill non-fatal: pid=#{pid_str} output=#{String.trim(output)}")
          :ok
        end
    end
  end

  def kill_tree(_os_pid, _opts), do: :ok
end

defmodule SymphonyElixir.AgentRunner.ProcessKiller.UnixSigterm do
  @moduledoc """
  Kills a process tree on Unix via SIGTERM to the process group.
  """

  @behaviour SymphonyElixir.AgentRunner.ProcessKiller

  @impl true
  def kill_tree(os_pid, _opts) when is_integer(os_pid) and os_pid > 0 do
    # Send SIGTERM to the process group
    case System.cmd("kill", ["-TERM", "--", "-#{os_pid}"], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, _} ->
        if String.contains?(output, "No such process") do
          :ok
        else
          {:error, {:kill_failed, output}}
        end
    end
  end

  def kill_tree(_os_pid, _opts), do: :ok
end

defmodule SymphonyElixir.AgentRunner.ProcessKiller.Mock do
  @moduledoc """
  Mock process killer for testing. Records kill calls in the caller's process.
  """

  @behaviour SymphonyElixir.AgentRunner.ProcessKiller

  @impl true
  def kill_tree(os_pid, _opts) when is_integer(os_pid) and os_pid > 0 do
    send(Process.get(:process_killer_test_pid, self()), {:process_killer_kill, os_pid})
    :ok
  end

  def kill_tree(_os_pid, _opts), do: :ok
end

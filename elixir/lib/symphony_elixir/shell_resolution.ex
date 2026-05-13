defmodule SymphonyElixir.ShellResolution do
  @moduledoc """
  Resolves the correct shell executable and arguments for the current platform.

  On POSIX systems: uses sh -lc <command>
  On Windows: falls back through pwsh -> powershell -> cmd /S /C
  """

  @spec resolve(String.t(), (String.t() -> String.t() | nil)) :: {String.t(), [String.t()]}
  def resolve(command, executable_resolver \\ &System.find_executable/1) do
    if windows?() do
      resolve_windows(command, executable_resolver)
    else
      {"sh", ["-lc", command]}
    end
  end

  @spec format_hook_error(String.t(), String.t(), {String.t(), non_neg_integer()}, {String.t(), [String.t()]}) :: map()
  def format_hook_error(hook_name, workspace, {output, exit_status}, {shell_executable, shell_args}) do
    command_preview = extract_command_preview(shell_args)

    %{
      hook_name: hook_name,
      workspace: workspace,
      shell_executable: shell_executable,
      command_preview: command_preview,
      exit_status: exit_status,
      output_preview: truncate_string(output, 500)
    }
  end

  defp windows? do
    case Application.get_env(:symphony_elixir, :os_type) do
      :unix -> false
      :windows -> true
      nil -> :os.type() |> elem(0) == :win32
    end
  end

  defp resolve_windows(command, resolver) do
    cond do
      resolver.("pwsh") != nil ->
        {"pwsh", ["-NoProfile", "-Command", command]}

      resolver.("powershell") != nil ->
        {"powershell", ["-NoProfile", "-Command", command]}

      true ->
        {"cmd", ["/S", "/C", command]}
    end
  end

  defp extract_command_preview(["-lc", cmd]), do: cmd
  defp extract_command_preview(["-NoProfile", "-Command", cmd]), do: cmd
  defp extract_command_preview(["/S", "/C", cmd]), do: cmd
  defp extract_command_preview(args), do: Enum.join(args, " ")

  defp truncate_string(str, max_len) when is_binary(str) do
    if String.length(str) > max_len do
      String.slice(str, 0, max_len) <> "..."
    else
      str
    end
  end
end

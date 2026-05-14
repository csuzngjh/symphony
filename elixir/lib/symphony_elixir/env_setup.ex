defmodule SymphonyElixir.EnvSetup do
  @moduledoc """
  Ensures the BEAM process inherits the full user PATH from the Windows registry.

  On Windows, IDE-launched processes may not receive the complete user PATH
  (e.g. npm global directory, Git cmd directory). This module reads the system
  and user PATH from the Windows registry at startup and merges missing entries
  into the current process environment, so that `System.find_executable/1` can
  locate tools like git, npm, node, and acpx.
  """

  require Logger

  @spec ensure_full_path :: :ok
  def ensure_full_path do
    if windows?() do
      merge_registry_path()
    else
      :ok
    end
  end

  defp windows? do
    :os.type() |> elem(0) == :win32
  end

  defp merge_registry_path do
    current_path = System.get_env("PATH") || ""

    system_path = read_reg_path("HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment")
    user_path = read_reg_path("HKCU\\Environment")

    registry_path = [system_path, user_path] |> Enum.filter(&(&1 != "")) |> Enum.join(";")

    if registry_path != "" do
      missing = find_missing_dirs(current_path, registry_path)

      if missing != [] do
        merged = Enum.join(missing, ";") <> ";" <> current_path
        System.put_env("PATH", merged)
        Logger.info("EnvSetup merged #{length(missing)} PATH entries from Windows registry")
      end
    end

    :ok
  rescue
    e ->
      Logger.warning("EnvSetup failed to merge registry PATH: #{Exception.message(e)}")
      :ok
  end

  defp read_reg_path(key) do
    system_root = System.get_env("SystemRoot") || "C:\\Windows"
    reg_path = Path.join(system_root, "System32\\reg.exe")

    if File.exists?(reg_path) do
      case System.cmd(reg_path, ["query", key, "/v", "Path"], stderr_to_stdout: true) do
        {output, 0} ->
          parse_reg_path_output(output)

        _ ->
          ""
      end
    else
      ""
    end
  rescue
    _ -> ""
  end

  defp parse_reg_path_output(output) do
    output
    |> String.split("\n")
    |> Enum.find_value("", fn line ->
      if String.contains?(line, "REG_EXPAND_SZ") or String.contains?(line, "REG_SZ") do
        line
        |> String.split(~r/REG_EXPAND_SZ|REG_SZ/, parts: 2)
        |> List.last()
        |> String.trim()
      else
        nil
      end
    end)
    |> expand_env_vars()
  end

  defp expand_env_vars(path) do
    env_vars = %{
      "%SystemRoot%" => System.get_env("SystemRoot") || "C:\\Windows",
      "%PROGRAMFILES%" => System.get_env("ProgramFiles") || "C:\\Program Files",
      "%PROGRAMFILES(X86)%" => System.get_env("ProgramFiles(x86)") || "C:\\Program Files (x86)",
      "%PROGRAMW6432%" => System.get_env("ProgramW6432") || "C:\\Program Files",
      "%SYSTEMROOT%" => System.get_env("SystemRoot") || "C:\\Windows"
    }

    Enum.reduce(env_vars, path, fn {pattern, replacement}, acc ->
      String.replace(acc, pattern, replacement)
    end)
  end

  defp find_missing_dirs(current_path, registry_path) do
    current_dirs =
      current_path
      |> String.split(";")
      |> Enum.map(&String.downcase(String.trim(&1)))
      |> MapSet.new()

    registry_path
    |> String.split(";")
    |> Enum.filter(fn dir ->
      dir = String.trim(dir)
      dir != "" and String.downcase(dir) not in current_dirs
    end)
  end
end

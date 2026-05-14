defmodule SymphonyElixir.ShellResolutionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ShellResolution

  describe "resolve/2" do
    test "returns sh -lc when sh exists (POSIX)" do
      resolver = fn
        "sh" -> "/usr/bin/sh"
        _ -> nil
      end

      original = Application.get_env(:symphony_elixir, :os_type)

      try do
        Application.put_env(:symphony_elixir, :os_type, :unix)
        assert ShellResolution.resolve("echo hello", resolver) == {"sh", ["-lc", "echo hello"]}
      after
        if original, do: Application.put_env(:symphony_elixir, :os_type, original), else: Application.delete_env(:symphony_elixir, :os_type)
      end
    end

    test "returns git bash when available (Windows)" do
      resolver = fn
        "sh" -> nil
        "git" -> nil
        "pwsh" -> "/usr/bin/pwsh"
        _ -> nil
      end

      original = Application.get_env(:symphony_elixir, :os_type)

      try do
        Application.put_env(:symphony_elixir, :os_type, :windows)

        {shell_exec, shell_args} = ShellResolution.resolve("echo hello", resolver)

        if shell_exec =~ "bash" do
          assert shell_args == ["-c", "echo hello"]
        else
          assert shell_exec == "/usr/bin/pwsh"
          assert shell_args == ["-NoProfile", "-Command", "echo hello"]
        end
      after
        if original, do: Application.put_env(:symphony_elixir, :os_type, original), else: Application.delete_env(:symphony_elixir, :os_type)
      end
    end

    test "returns pwsh when git bash missing and pwsh exists (Windows)" do
      resolver = fn
        "sh" -> nil
        "git" -> nil
        "pwsh" -> "/usr/bin/pwsh"
        _ -> nil
      end

      original = Application.get_env(:symphony_elixir, :os_type)
      original_bash_dirs = Application.get_env(:symphony_elixir, :git_bash_dirs)

      try do
        Application.put_env(:symphony_elixir, :os_type, :windows)
        Application.put_env(:symphony_elixir, :git_bash_dirs, [])

        assert ShellResolution.resolve("echo hello", resolver) == {"/usr/bin/pwsh", ["-NoProfile", "-Command", "echo hello"]}
      after
        if original, do: Application.put_env(:symphony_elixir, :os_type, original), else: Application.delete_env(:symphony_elixir, :os_type)
        if original_bash_dirs, do: Application.put_env(:symphony_elixir, :git_bash_dirs, original_bash_dirs), else: Application.delete_env(:symphony_elixir, :git_bash_dirs)
      end
    end

    test "returns powershell when git bash and pwsh missing (Windows)" do
      resolver = fn
        "sh" -> nil
        "pwsh" -> nil
        "powershell" -> ~S(C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe)
        _ -> nil
      end

      original = Application.get_env(:symphony_elixir, :os_type)
      original_bash_dirs = Application.get_env(:symphony_elixir, :git_bash_dirs)

      try do
        Application.put_env(:symphony_elixir, :os_type, :windows)
        Application.put_env(:symphony_elixir, :git_bash_dirs, [])

        assert ShellResolution.resolve("echo hello", resolver) == {~S(C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe), ["-NoProfile", "-Command", "echo hello"]}
      after
        if original, do: Application.put_env(:symphony_elixir, :os_type, original), else: Application.delete_env(:symphony_elixir, :os_type)
        if original_bash_dirs, do: Application.put_env(:symphony_elixir, :git_bash_dirs, original_bash_dirs), else: Application.delete_env(:symphony_elixir, :git_bash_dirs)
      end
    end

    test "returns cmd /S /C when no shell exists (Windows fallback)" do
      resolver = fn _ -> nil end

      original = Application.get_env(:symphony_elixir, :os_type)
      original_bash_dirs = Application.get_env(:symphony_elixir, :git_bash_dirs)

      try do
        Application.put_env(:symphony_elixir, :os_type, :windows)
        Application.put_env(:symphony_elixir, :git_bash_dirs, [])

        assert ShellResolution.resolve("echo hello", resolver) == {"cmd", ["/S", "/C", "echo hello"]}
      after
        if original, do: Application.put_env(:symphony_elixir, :os_type, original), else: Application.delete_env(:symphony_elixir, :os_type)
        if original_bash_dirs, do: Application.put_env(:symphony_elixir, :git_bash_dirs, original_bash_dirs), else: Application.delete_env(:symphony_elixir, :git_bash_dirs)
      end
    end

    test "non-Windows falls back to sh even if not found" do
      resolver = fn _ -> nil end

      original = Application.get_env(:symphony_elixir, :os_type)

      try do
        Application.put_env(:symphony_elixir, :os_type, :unix)
        assert ShellResolution.resolve("echo hello", resolver) == {"sh", ["-lc", "echo hello"]}
      after
        if original, do: Application.put_env(:symphony_elixir, :os_type, original), else: Application.delete_env(:symphony_elixir, :os_type)
      end
    end

    test "preserves complex commands with pipes" do
      resolver = fn
        "sh" -> "/usr/bin/sh"
        _ -> nil
      end

      original = Application.get_env(:symphony_elixir, :os_type)

      try do
        Application.put_env(:symphony_elixir, :os_type, :unix)
        assert ShellResolution.resolve("git clone foo && npm install", resolver) == {"sh", ["-lc", "git clone foo && npm install"]}
      after
        if original, do: Application.put_env(:symphony_elixir, :os_type, original), else: Application.delete_env(:symphony_elixir, :os_type)
      end
    end
  end

  describe "format_hook_error/4" do
    test "includes shell, command, exit status, and output preview" do
      error =
        ShellResolution.format_hook_error(
          "after_create",
          "/workspace/PRI-123",
          {"command not found", 127},
          {"sh", ["-lc", "git clone foo"]}
        )

      assert error.hook_name == "after_create"
      assert error.workspace == "/workspace/PRI-123"
      assert error.shell_executable == "sh"
      assert error.exit_status == 127
      assert error.output_preview == "command not found"
      assert error.command_preview == "git clone foo"
    end
  end
end

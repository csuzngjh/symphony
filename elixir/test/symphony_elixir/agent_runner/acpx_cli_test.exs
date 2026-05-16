defmodule SymphonyElixir.AgentRunner.AcpxCliTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRunner.AcpxCli

  setup do
    # Ensure no ACPX_COMMAND pollution from test_helper (fake ACPX mode)
    original = System.get_env("ACPX_COMMAND")
    original_original = System.get_env("ACPX_COMMAND_ORIGINAL")
    on_exit(fn ->
      if original do
        System.put_env("ACPX_COMMAND", original)
      else
        System.delete_env("ACPX_COMMAND")
      end
      if original_original do
        System.put_env("ACPX_COMMAND_ORIGINAL", original_original)
      else
        System.delete_env("ACPX_COMMAND_ORIGINAL")
      end
    end)
    :ok
  end

  describe "resolve_strategy/3" do
    test "ACPX_COMMAND env var overrides everything" do
      original = System.get_env("ACPX_COMMAND")

      try do
        System.put_env("ACPX_COMMAND", "/usr/local/bin/acpx")
        file_resolver = fn _ -> true end
        exe_resolver = fn _ -> nil end
        npm_resolver = fn -> {"", 1} end

        assert {:direct, "/usr/local/bin/acpx"} = AcpxCli.resolve_strategy(file_resolver, exe_resolver, npm_resolver)
      after
        if original, do: System.put_env("ACPX_COMMAND", original), else: System.delete_env("ACPX_COMMAND")
      end
    end

    test "POSIX returns direct when acpx is real executable" do
      original_os = Application.get_env(:symphony_elixir, :os_type)

      try do
        Application.put_env(:symphony_elixir, :os_type, :unix)
        System.delete_env("ACPX_COMMAND")
        System.delete_env("ACPX_COMMAND_ORIGINAL")

        exe_resolver = fn
          "acpx" -> "/usr/local/bin/acpx"
          _ -> nil
        end

        file_resolver = fn _ -> true end
        npm_resolver = fn -> {"", 1} end

        assert {:direct, "/usr/local/bin/acpx"} = AcpxCli.resolve_strategy(file_resolver, exe_resolver, npm_resolver)
      after
        if original_os, do: Application.put_env(:symphony_elixir, :os_type, original_os), else: Application.delete_env(:symphony_elixir, :os_type)
      end
    end

    test "Windows with .ps1 shim falls back to shell acpx command" do
      original_os = Application.get_env(:symphony_elixir, :os_type)

      try do
        Application.put_env(:symphony_elixir, :os_type, :windows)

        exe_resolver = fn
          "acpx" -> "C:\\Users\\test\\npm\\acpx.ps1"
          "cmd" -> "C:\\Windows\\System32\\cmd.exe"
          "node" -> "C:\\Program Files\\nodejs\\node.exe"
          _ -> nil
        end

        file_resolver = fn path -> String.contains?(path, "cli.js") end
        npm_resolver = fn -> {"C:\\Users\\test\\npm", 0} end

        assert {:shell, "C:\\Windows\\System32\\cmd.exe", ["/S", "/C", "acpx"]} =
                 AcpxCli.resolve_strategy(file_resolver, exe_resolver, npm_resolver)
      after
        if original_os, do: Application.put_env(:symphony_elixir, :os_type, original_os), else: Application.delete_env(:symphony_elixir, :os_type)
      end
    end

    test "ACPX_JS_PATH env var with .js file uses node_js" do
      original = System.get_env("ACPX_JS_PATH")

      try do
        System.put_env("ACPX_JS_PATH", "/opt/acpx/dist/cli.js")

        exe_resolver = fn
          "node" -> "/usr/bin/node"
          _ -> nil
        end

        file_resolver = fn
          "/opt/acpx/dist/cli.js" -> true
          _ -> false
        end

        npm_resolver = fn -> {"", 1} end

        assert {:node_js, "/usr/bin/node", "/opt/acpx/dist/cli.js"} = AcpxCli.resolve_strategy(file_resolver, exe_resolver, npm_resolver)
      after
        if original, do: System.put_env("ACPX_JS_PATH", original), else: System.delete_env("ACPX_JS_PATH")
      end
    end

    test "ACPX_JS_PATH with non-.js file is rejected" do
      original = System.get_env("ACPX_JS_PATH")

      try do
        System.put_env("ACPX_JS_PATH", "/opt/acpx/dist/cli.ps1")
        exe_resolver = fn _ -> nil end
        file_resolver = fn _ -> true end
        npm_resolver = fn -> {"", 1} end

        assert {:error, _} = AcpxCli.resolve_strategy(file_resolver, exe_resolver, npm_resolver)
      after
        if original, do: System.put_env("ACPX_JS_PATH", original), else: System.delete_env("ACPX_JS_PATH")
      end
    end

    test "returns error when nothing is found" do
      original_os = Application.get_env(:symphony_elixir, :os_type)

      try do
        Application.put_env(:symphony_elixir, :os_type, :windows)
        exe_resolver = fn _ -> nil end
        file_resolver = fn _ -> false end
        npm_resolver = fn -> {"", 1} end

        assert {:error, msg} = AcpxCli.resolve_strategy(file_resolver, exe_resolver, npm_resolver)
        assert is_binary(msg)
      after
        if original_os, do: Application.put_env(:symphony_elixir, :os_type, original_os), else: Application.delete_env(:symphony_elixir, :os_type)
      end
    end

    test "npm global prefix resolves cli.js" do
      original_os = Application.get_env(:symphony_elixir, :os_type)

      try do
        Application.put_env(:symphony_elixir, :os_type, :windows)

        exe_resolver = fn
          "node" -> "C:\\nodejs\\node.exe"
          _ -> nil
        end

        file_resolver = fn path -> String.ends_with?(path, "cli.js") end
        npm_resolver = fn -> {"C:\\Users\\test\\npm", 0} end

        assert {:node_js, "C:\\nodejs\\node.exe", js_path} = AcpxCli.resolve_strategy(file_resolver, exe_resolver, npm_resolver)
        assert String.ends_with?(js_path, "cli.js")
      after
        if original_os, do: Application.put_env(:symphony_elixir, :os_type, original_os), else: Application.delete_env(:symphony_elixir, :os_type)
      end
    end
  end

  describe "strategy_label/1" do
    test "labels direct strategy" do
      assert AcpxCli.strategy_label({:direct, "/usr/bin/acpx"}) =~ "direct"
    end

    test "labels node_js strategy" do
      assert AcpxCli.strategy_label({:node_js, "/usr/bin/node", "/opt/acpx/cli.js"}) =~ "node+js"
    end

    test "labels shell strategy" do
      assert AcpxCli.strategy_label({:shell, "cmd", ["/S", "/C", "acpx"]}) =~ "shell"
    end

    test "labels error strategy" do
      assert AcpxCli.strategy_label({:error, "not found"}) =~ "error"
    end
  end
end

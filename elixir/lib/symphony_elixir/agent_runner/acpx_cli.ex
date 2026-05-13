defmodule SymphonyElixir.AgentRunner.AcpxCli do
  @moduledoc """
  Resolves the ACPX CLI execution strategy for the current platform.

  Prefer running the same `acpx` command that works in the user's terminal.
  On Windows, npm may expose `acpx` as a PowerShell/cmd shim; when direct
  execution is not safe, run it through `cmd /S /C acpx` instead of trying to
  parse the shim as JavaScript.

  ## Execution strategies

  - `{:direct, executable}` - spawn the executable directly
  - `{:shell, executable, prefix_args}` - spawn a shell wrapper, appending ACPX args
  - `{:node_js, node_path, js_path}` - optional fallback for explicit JS CLI
  - `{:error, message}` - no viable strategy found

  ## Priority order

  1. `ACPX_COMMAND` env var (user override, any platform)
  2. Direct `acpx` executable when it is a real executable
  3. Windows shell fallback: `cmd /S /C acpx`
  4. `ACPX_JS_PATH` env var + node (manual escape hatch)
  """

  @non_executable_extensions ~w(.ps1 .cmd .bat)

  @type execution_strategy ::
          {:direct, String.t()}
          | {:shell, String.t(), [String.t()]}
          | {:node_js, String.t(), String.t()}
          | {:error, String.t()}

  @type file_exists_resolver :: (String.t() -> boolean())
  @type executable_resolver :: (String.t() -> String.t() | nil)
  @type npm_prefix_resolver :: {String.t(), integer()} | {:error, term()}

  @spec resolve_strategy(
          file_exists_resolver(),
          executable_resolver(),
          npm_prefix_resolver()
        ) :: execution_strategy()
  def resolve_strategy(
        file_exists_resolver \\ &File.exists?/1,
        executable_resolver \\ &System.find_executable/1,
        npm_prefix_resolver \\ &npm_prefix/0
      ) do
    explicit = System.get_env("ACPX_COMMAND")

    cond do
      is_binary(explicit) and explicit != "" ->
        resolve_explicit_command(explicit, file_exists_resolver, executable_resolver, npm_prefix_resolver)

      direct_acpx_path = executable_resolver.("acpx") ->
        resolve_found_acpx(direct_acpx_path, executable_resolver, file_exists_resolver, npm_prefix_resolver)

      true ->
        resolve_shell_or_node_strategy(file_exists_resolver, executable_resolver, npm_prefix_resolver)
    end
  end

  defp resolve_explicit_command(explicit, file_exists_resolver, executable_resolver, npm_prefix_resolver) do
    if file_exists_resolver.(explicit) do
      case Path.extname(explicit) do
        ".js" ->
          node = executable_resolver.("node")
          if node, do: {:node_js, node, explicit}, else: {:error, "node not found for ACPX_COMMAND=.js"}

        ext when ext in @non_executable_extensions ->
          resolve_shell_strategy(executable_resolver) ||
            resolve_node_js_strategy(file_exists_resolver, executable_resolver, npm_prefix_resolver)

        _ ->
          {:direct, explicit}
      end
    else
      resolve_shell_or_node_strategy(file_exists_resolver, executable_resolver, npm_prefix_resolver)
    end
  end

  defp resolve_found_acpx(path, executable_resolver, file_exists_resolver, npm_prefix_resolver) do
    case String.downcase(Path.extname(path)) do
      ext when ext in @non_executable_extensions ->
        resolve_shell_strategy(executable_resolver) ||
          resolve_node_js_strategy(file_exists_resolver, executable_resolver, npm_prefix_resolver)

      _ ->
        {:direct, path}
    end
  end

  defp resolve_shell_or_node_strategy(file_exists_resolver, executable_resolver, npm_prefix_resolver) do
    resolve_shell_strategy(executable_resolver) ||
      resolve_node_js_strategy(file_exists_resolver, executable_resolver, npm_prefix_resolver)
  end

  defp resolve_shell_strategy(executable_resolver) do
    case Application.get_env(:symphony_elixir, :os_type) do
      :windows ->
        shell_strategy(executable_resolver)

      nil ->
        case :os.type() do
          {:win32, _} -> shell_strategy(executable_resolver)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp shell_strategy(executable_resolver) do
    case executable_resolver.("cmd") do
      nil -> nil
      cmd -> {:shell, cmd, ["/S", "/C", "acpx"]}
    end
  end

  defp resolve_node_js_strategy(file_exists_resolver, executable_resolver, npm_prefix_resolver) do
    explicit_js = System.get_env("ACPX_JS_PATH")

    cond do
      is_binary(explicit_js) and String.ends_with?(explicit_js, ".js") and file_exists_resolver.(explicit_js) ->
        node = executable_resolver.("node")
        if node, do: {:node_js, node, explicit_js}, else: {:error, "node not found for ACPX_JS_PATH"}

      true ->
        case npm_cli_path(npm_prefix_resolver, file_exists_resolver) do
          nil ->
            {:error, "Cannot locate acpx CLI. Install with: npm install -g acpx"}

          js_path ->
            node = executable_resolver.("node")
            if node, do: {:node_js, node, js_path}, else: {:error, "node not found for acpx JS CLI"}
        end
    end
  end

  defp npm_cli_path(npm_prefix_resolver, file_exists_resolver) do
    case npm_prefix_resolver.() do
      {prefix, 0} ->
        prefix = String.trim(prefix)
        js_path = Path.join([prefix, "node_modules", "acpx", "dist", "cli.js"])
        if file_exists_resolver.(js_path), do: js_path, else: nil

      _ ->
        nil
    end
  end

  @spec npm_prefix() :: {String.t(), integer()} | {:error, term()}
  def npm_prefix do
    case Application.get_env(:symphony_elixir, :os_type) || :os.type() do
      :windows ->
        System.cmd("cmd", ["/S", "/C", "npm config get prefix"], [])

      {:win32, _} ->
        System.cmd("cmd", ["/S", "/C", "npm config get prefix"], [])

      _ ->
        case System.cmd("npm", ["config", "get", "prefix"], []) do
          {prefix, 0} -> {prefix, 0}
          _ -> fallback_npm_prefix()
        end
    end
  end

  defp fallback_npm_prefix do
    case System.get_env("APPDATA") do
      nil -> {:error, :no_appdata}
      appdata -> {Path.join(appdata, "npm"), 0}
    end
  end

  @spec strategy_label(execution_strategy()) :: String.t()
  def strategy_label({:direct, path}), do: "direct (#{path})"
  def strategy_label({:shell, path, prefix}), do: "shell (#{path} #{Enum.join(prefix, " ")})"
  def strategy_label({:node_js, _node, js}), do: "node+js (#{js})"
  def strategy_label({:error, msg}), do: "error (#{msg})"
end

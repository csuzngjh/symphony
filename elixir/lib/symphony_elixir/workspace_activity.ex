defmodule SymphonyElixir.WorkspaceActivity do
  @moduledoc false

  @skip_dirs MapSet.new(~w(node_modules .git _build deps .elixir_ls))
  @max_scan_depth 3
  @git_cmd_timeout_ms 5_000

  @spec scan_workspace_activity(Path.t(), DateTime.t() | nil) ::
          {:active, DateTime.t()} | {:stale, nil}
  def scan_workspace_activity(workspace_path, since) do
    case last_activity_mtime(workspace_path, since) do
      nil -> {:stale, nil}
      mtime -> {:active, mtime}
    end
  rescue
    _ -> {:stale, nil}
  end

  @spec last_activity_mtime(Path.t(), DateTime.t() | nil) :: DateTime.t() | nil
  def last_activity_mtime(workspace_path, since) do
    cond do
      is_nil(workspace_path) -> nil
      not File.dir?(workspace_path) -> nil
      File.dir?(Path.join(workspace_path, ".git")) -> git_activity_mtime(workspace_path, since)
      true -> directory_activity_mtime(workspace_path, since)
    end
  rescue
    _ -> nil
  end

  defp git_activity_mtime(workspace_path, since) do
    modified = git_cmd(workspace_path, ["diff", "--name-only", "HEAD"])
    untracked = git_cmd(workspace_path, ["ls-files", "--others", "--exclude-standard"])

    (modified ++ untracked)
    |> Enum.map(&Path.join(workspace_path, &1))
    |> collect_mtimes()
    |> filter_since(since)
    |> max_datetime()
  end

  defp directory_activity_mtime(workspace_path, since) do
    workspace_path
    |> walk_dir(0)
    |> collect_mtimes()
    |> filter_since(since)
    |> max_datetime()
  end

  defp git_cmd(workspace_path, args) do
    parent = self()
    ref = make_ref()

    pid = spawn(fn ->
      result =
        try do
          case System.cmd("git", args, cd: workspace_path, stderr_to_stdout: true) do
            {output, 0} -> String.split(output, "\n", trim: true)
            {_output, _} -> []
          end
        rescue
          _ -> []
        end

      send(parent, {ref, result})
    end)

    receive do
      {^ref, result} -> result
    after
      @git_cmd_timeout_ms ->
        Process.exit(pid, :kill)
        []
    end
  rescue
    _ -> []
  end

  defp walk_dir(_dir, depth) when depth > @max_scan_depth, do: []

  defp walk_dir(dir, depth) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full_path = Path.join(dir, entry)

          cond do
            MapSet.member?(@skip_dirs, entry) -> []
            File.dir?(full_path) -> walk_dir(full_path, depth + 1)
            true -> [full_path]
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp collect_mtimes(paths) do
    Enum.flat_map(paths, fn path ->
      case File.stat(path, time: :local) do
        {:ok, %File.Stat{mtime: mtime}} -> [erlang_datetime_to_datetime(mtime)]
        {:error, _} -> []
      end
    end)
  end

  defp filter_since(mtimes, nil), do: mtimes

  defp filter_since(mtimes, since) do
    Enum.filter(mtimes, &(DateTime.compare(&1, since) == :gt))
  end

  defp max_datetime([]), do: nil
  defp max_datetime(mtimes), do: Enum.max(mtimes, DateTime)

  defp erlang_datetime_to_datetime({{year, month, day}, {hour, min, sec}}) do
    local_erl = {{year, month, day}, {hour, min, sec}}

    case :calendar.local_time_to_universal_time_dst(local_erl) do
      [utc_erl | _] ->
        {{y, m, d}, {h, mi, s}} = utc_erl
        {:ok, naive} = NaiveDateTime.new(y, m, d, h, mi, s)
        DateTime.from_naive!(naive, "Etc/UTC")

      [] ->
        {:ok, naive} = NaiveDateTime.new(year, month, day, hour, min, sec)
        DateTime.from_naive!(naive, "Etc/UTC")
    end
  end
end

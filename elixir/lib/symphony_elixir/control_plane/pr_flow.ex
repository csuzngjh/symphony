defmodule SymphonyElixir.ControlPlane.PrFlow do
  @moduledoc """
  Owns deterministic branch, commit, push, PR, and tracker transition steps.

  Agent processes may edit files and run tests, but they must not push branches,
  create pull requests, or move tracker state.  This module keeps those
  side-effects in the Symphony control plane so they can be tested and audited.
  """

  alias SymphonyElixir.ControlPlane.CompletionReport
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker

  @forbidden_path_prefixes [".trae/", ".planning/", "tmp-", "test-output"]
  @control_plane_changed_files [".symphony/agent-completion.json"]

  @type command_runner ::
          (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})

  @type success :: %{
          changed_files: [String.t()],
          branch_name: String.t(),
          commit_sha: String.t() | nil,
          pr_url: String.t()
        }

  @spec run(Issue.t(), Path.t(), keyword()) :: {:ok, success()} | {:error, term()}
  def run(%Issue{} = issue, workspace_path, opts \\ [])
      when is_binary(workspace_path) do
    branch_name = Keyword.fetch!(opts, :branch_name)
    base_branch = Keyword.get(opts, :base_branch, "main")
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)
    tracker_update = Keyword.get(opts, :tracker_update, &Tracker.update_issue_state/2)

    with {:ok, changed_files} <- changed_files(workspace_path, command_runner),
         :ok <- validate_changed_files(changed_files),
         {:ok, completion_report} <- CompletionReport.read(workspace_path),
         {:ok, _report} <- CompletionReport.validate(completion_report, changed_files: changed_files, command_runner: command_runner),
         :ok <- git_add(workspace_path, changed_files, command_runner),
         :ok <- git_commit(workspace_path, issue, command_runner),
         {:ok, commit_sha} <- git_rev_parse(workspace_path, command_runner),
         :ok <- git_push(workspace_path, branch_name, command_runner),
         {:ok, pr_url} <- gh_pr_create(workspace_path, issue, branch_name, base_branch, command_runner),
         :ok <- tracker_update.(issue.id, "In Review") do
      {:ok,
       %{
         changed_files: changed_files,
         branch_name: branch_name,
         commit_sha: commit_sha,
         pr_url: pr_url
       }}
    else
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_pr_flow_result, other}}
    end
  end

  @spec changed_files(Path.t(), command_runner()) :: {:ok, [String.t()]} | {:error, term()}
  def changed_files(workspace_path, command_runner \\ &System.cmd/3) do
    case command_runner.("git", ["status", "--porcelain"], cd: workspace_path, stderr_to_stdout: true) do
      {"", 0} -> {:error, :no_changes}
      {output, 0} -> parsed_changed_files(output)
      {output, status} -> {:error, {:git_status_failed, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:git_status_exception, Exception.message(error)}}
  end

  defp parsed_changed_files(output) when is_binary(output) do
    output
    |> parse_porcelain()
    |> Enum.reject(&control_plane_changed_file?/1)
    |> case do
      [] -> {:error, :no_changes}
      changed_files -> {:ok, changed_files}
    end
  end

  @spec validate_changed_files([String.t()]) :: :ok | {:error, term()}
  def validate_changed_files(changed_files) when is_list(changed_files) do
    case Enum.find(changed_files, &forbidden_path?/1) do
      nil -> :ok
      path -> {:error, {:forbidden_changed_file, path}}
    end
  end

  defp parse_porcelain(output) when is_binary(output) do
    output
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.map(&parse_porcelain_line/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_porcelain_line(line) when byte_size(line) >= 4 do
    line
    |> String.slice(3..-1//1)
    |> String.trim()
    |> normalize_git_path()
  end

  defp parse_porcelain_line(line), do: String.trim(line)

  defp normalize_git_path(path) do
    path
    |> String.replace("\\", "/")
    |> strip_rename_source()
  end

  defp strip_rename_source(path) do
    case String.split(path, " -> ", parts: 2) do
      [_from, to] -> to
      [single] -> single
    end
  end

  defp forbidden_path?(path) when is_binary(path) do
    normalized =
      path
      |> normalize_git_path()
      |> String.trim_leading("/")

    Enum.any?(@forbidden_path_prefixes, fn prefix ->
      String.starts_with?(normalized, prefix)
    end)
  end

  defp control_plane_changed_file?(path) when is_binary(path) do
    normalized =
      path
      |> normalize_git_path()
      |> String.trim_leading("/")

    normalized in @control_plane_changed_files
  end

  defp control_plane_changed_file?(_), do: false

  defp git_add(workspace_path, changed_files, command_runner) do
    case command_runner.("git", ["add", "--" | changed_files], cd: workspace_path, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:git_add_failed, status, String.trim(output)}}
    end
  end

  defp git_commit(workspace_path, issue, command_runner) do
    message = commit_message(issue)

    case command_runner.("git", ["commit", "-m", message], cd: workspace_path, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:git_commit_failed, status, String.trim(output)}}
    end
  end

  defp git_rev_parse(workspace_path, command_runner) do
    case command_runner.("git", ["rev-parse", "HEAD"], cd: workspace_path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:git_rev_parse_failed, status, String.trim(output)}}
    end
  end

  defp git_push(workspace_path, branch_name, command_runner) do
    case command_runner.("git", ["push", "-u", "origin", branch_name], cd: workspace_path, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:git_push_failed, status, String.trim(output)}}
    end
  end

  defp gh_pr_create(workspace_path, issue, branch_name, base_branch, command_runner) do
    args = [
      "pr",
      "create",
      "--head",
      branch_name,
      "--base",
      base_branch,
      "--title",
      pr_title(issue),
      "--body",
      pr_body(issue)
    ]

    case command_runner.("gh", args, cd: workspace_path, stderr_to_stdout: true) do
      {output, 0} -> parse_pr_url(output)
      {output, status} -> {:error, {:gh_pr_create_failed, status, String.trim(output)}}
    end
  end

  defp parse_pr_url(output) do
    case output
         |> String.split()
         |> Enum.find(&String.starts_with?(&1, "http")) do
      nil -> {:error, {:gh_pr_create_missing_url, String.trim(output)}}
      pr_url -> {:ok, pr_url}
    end
  end

  defp commit_message(%Issue{identifier: identifier, title: title}) do
    "fix(#{String.downcase(identifier || "issue")}): #{String.trim(title || "agent changes")}"
    |> String.slice(0, 200)
  end

  defp pr_title(%Issue{identifier: identifier, title: title}) do
    "#{identifier}: #{String.trim(title || "Agent changes")}"
  end

  defp pr_body(%Issue{} = issue) do
    """
    ## Summary

    Symphony control plane created this PR for #{issue.identifier}.

    ## Issue

    #{issue.url || issue.id}

    ## Notes

    The agent edited the workspace only. Symphony performed commit, push, PR creation, and tracker transition.
    """
  end
end

defmodule SymphonyElixir.ControlPlane.CompletionReport do
  alias SymphonyElixir.ControlPlane.PrFlow

  @type command_runner ::
          (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})

  @completion_dir ".symphony"
  @completion_file "agent-completion.json"
  @control_plane_changed_files [Path.join(@completion_dir, @completion_file)]

  @spec read(Path.t()) :: {:ok, map()} | {:error, :missing_completion_report} | {:error, :invalid_completion_report}
  def read(workspace_path) when is_binary(workspace_path) do
    path = Path.join([workspace_path, @completion_dir, @completion_file])

    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, report} when is_map(report) -> {:ok, report}
          _ -> {:error, :invalid_completion_report}
        end

      {:error, :enoent} ->
        {:error, :missing_completion_report}

      {:error, _} ->
        {:error, :invalid_completion_report}
    end
  end

  @spec validate(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate(report, opts \\ []) when is_map(report) and is_list(opts) do
    changed_files_opt = Keyword.get(opts, :changed_files)
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)

    with :ok <- validate_status(report),
         :ok <- do_validate_changed_files(report, changed_files_opt, command_runner),
         :ok <- validate_tests(report) do
      {:ok, report}
    end
  end

  @spec validate_changed_files(map(), keyword()) :: :ok | {:error, :completion_changed_files_mismatch}
  def validate_changed_files(report, opts) when is_map(report) and is_list(opts) do
    changed_files_opt = Keyword.get(opts, :changed_files)
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)
    do_validate_changed_files(report, changed_files_opt, command_runner)
  end

  @spec validate_tests(map()) :: :ok | {:error, :completion_no_tests}
  def validate_tests(report) when is_map(report) do
    tests = Map.get(report, "tests", [])

    if is_list(tests) and Enum.any?(tests, &valid_test_entry?/1) do
      :ok
    else
      {:error, :completion_no_tests}
    end
  end

  @spec validate_status(map()) :: :ok | {:error, {:agent_blocked, map()}} | {:error, {:invalid_status, term()}}
  def validate_status(report) when is_map(report) do
    status = Map.get(report, "status")

    cond do
      status == "ready_for_review" -> :ok
      status == "blocked" -> {:error, {:agent_blocked, report}}
      true -> {:error, {:invalid_status, status}}
    end
  end

  defp do_validate_changed_files(report, nil, command_runner) do
    workspace_path = Map.get(report, "workspace_path", "")

    case PrFlow.changed_files(workspace_path, command_runner) do
      {:ok, git_files} -> compare_changed_files(report, git_files)
      {:error, _} -> {:error, :completion_changed_files_mismatch}
    end
  end

  defp do_validate_changed_files(report, changed_files, _command_runner) when is_list(changed_files) do
    compare_changed_files(report, changed_files)
  end

  defp compare_changed_files(report, git_files) do
    report_files = report |> Map.get("changed_files", []) |> MapSet.new()

    actual_files =
      git_files
      |> Enum.reject(&control_plane_changed_file?/1)
      |> MapSet.new()

    if MapSet.equal?(report_files, actual_files) do
      :ok
    else
      {:error, :completion_changed_files_mismatch}
    end
  end

  defp valid_test_entry?(entry) when is_map(entry) do
    Map.has_key?(entry, "command") and Map.has_key?(entry, "result")
  end

  defp valid_test_entry?(_), do: false

  defp control_plane_changed_file?(path) when is_binary(path) do
    normalized =
      path
      |> String.replace("\\", "/")
      |> String.trim_leading("/")

    normalized in @control_plane_changed_files or normalized == "#{@completion_dir}/"
  end

  defp control_plane_changed_file?(_), do: false
end

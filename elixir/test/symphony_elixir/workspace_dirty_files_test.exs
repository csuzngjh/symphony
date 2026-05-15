defmodule SymphonyElixir.WorkspaceDirtyFilesTest do
  use SymphonyElixir.TestSupport

  describe "dirty_files/2" do
    test "returns {:clean, []} for a clean git repo" do
      if git_available?() do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-dirty-files-clean-#{System.unique_integer([:positive])}"
          )

        try do
          workspace_root = Path.join(test_root, "workspaces")

          write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

          assert {:ok, workspace} = Workspace.create_for_issue("DF-CLEAN")

          System.cmd("git", ["-C", workspace, "init", "-b", "main"])
          System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
          System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
          System.cmd("git", ["-C", workspace, "add", "."])
          System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])

          assert {:clean, []} = Workspace.dirty_files(workspace, nil)
        after
          File.rm_rf(test_root)
        end
      else
        IO.puts(:stderr, "SKIP: git not available in PATH")
      end
    end

    test "returns {:dirty, files} for a repo with uncommitted changes" do
      if git_available?() do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-dirty-files-dirty-#{System.unique_integer([:positive])}"
          )

        try do
          workspace_root = Path.join(test_root, "workspaces")

          write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

          assert {:ok, workspace} = Workspace.create_for_issue("DF-DIRTY")

          System.cmd("git", ["-C", workspace, "init", "-b", "main"])
          System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
          System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
          System.cmd("git", ["-C", workspace, "add", "."])
          System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])

          File.write!(Path.join(workspace, "modified.txt"), "changed\n")
          File.write!(Path.join(workspace, "new_file.txt"), "new\n")

          assert {:dirty, files} = Workspace.dirty_files(workspace, nil)
          assert "modified.txt" in files
          assert "new_file.txt" in files
        after
          File.rm_rf(test_root)
        end
      else
        IO.puts(:stderr, "SKIP: git not available in PATH")
      end
    end

    test "returns {:dirty, files} with subdirectory paths preserved" do
      if git_available?() do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-dirty-files-subdir-#{System.unique_integer([:positive])}"
          )

        try do
          workspace_root = Path.join(test_root, "workspaces")

          write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

          assert {:ok, workspace} = Workspace.create_for_issue("DF-SUBDIR")

          System.cmd("git", ["-C", workspace, "init", "-b", "main"])
          System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
          System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
          System.cmd("git", ["-C", workspace, "add", "."])
          System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])

          File.mkdir_p!(Path.join(workspace, "src"))
          File.write!(Path.join(workspace, "src/app.ex"), "code\n")

          assert {:dirty, files} = Workspace.dirty_files(workspace, nil)
          assert Enum.any?(files, &String.contains?(&1, "src"))
        after
          File.rm_rf(test_root)
        end
      else
        IO.puts(:stderr, "SKIP: git not available in PATH")
      end
    end

    test "returns {:unknown, []} for non-existent path" do
      missing_path =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-dirty-files-missing-#{System.unique_integer([:positive])}"
        )

      assert {:unknown, []} = Workspace.dirty_files(missing_path, nil)
    end

    test "returns {:unknown, []} for a directory that is not a git repo" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-dirty-files-nongit-#{System.unique_integer([:positive])}"
        )

      try do
        File.mkdir_p!(test_root)
        File.write!(Path.join(test_root, "plain.txt"), "not git\n")

        assert {:unknown, []} = Workspace.dirty_files(test_root, nil)
      after
        File.rm_rf(test_root)
      end
    end

    test "returns {:unknown, []} for remote workspace" do
      assert {:unknown, []} = Workspace.dirty_files("/some/workspace", "worker-01:2200")
    end

    test "strips git status indicators from file paths" do
      if git_available?() do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-dirty-files-indicators-#{System.unique_integer([:positive])}"
          )

        try do
          workspace_root = Path.join(test_root, "workspaces")

          write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

          assert {:ok, workspace} = Workspace.create_for_issue("DF-INDIC")

          System.cmd("git", ["-C", workspace, "init", "-b", "main"])
          System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
          System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
          System.cmd("git", ["-C", workspace, "add", "."])
          System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])

          File.write!(Path.join(workspace, "unstaged.txt"), "unstaged change\n")

          assert {:dirty, files} = Workspace.dirty_files(workspace, nil)
          Enum.each(files, fn file ->
            refute String.starts_with?(file, " ")
            refute String.starts_with?(file, "?")
            refute String.starts_with?(file, "M")
          end)
        after
          File.rm_rf(test_root)
        end
      else
        IO.puts(:stderr, "SKIP: git not available in PATH")
      end
    end
  end
end

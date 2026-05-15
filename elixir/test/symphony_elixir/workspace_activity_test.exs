defmodule SymphonyElixir.WorkspaceActivityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.WorkspaceActivity

  describe "scan_workspace_activity/2" do
    test "returns {:stale, nil} for nil workspace_path" do
      assert {:stale, nil} = WorkspaceActivity.scan_workspace_activity(nil, nil)
    end

    test "returns {:stale, nil} for non-existent path" do
      missing =
        Path.join(
          System.tmp_dir!(),
          "symphony-wa-missing-#{System.unique_integer([:positive])}"
        )

      assert {:stale, nil} = WorkspaceActivity.scan_workspace_activity(missing, nil)
    end

    test "git repo with recently modified file returns {:active, datetime}" do
      if git_available?() do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-wa-git-active-#{System.unique_integer([:positive])}"
          )

        try do
          File.mkdir_p!(test_root)
          System.cmd("git", ["init", "-b", "main"], cd: test_root)
          System.cmd("git", ["-C", test_root, "config", "user.name", "Test User"])
          System.cmd("git", ["-C", test_root, "config", "user.email", "test@example.com"])

          File.write!(Path.join(test_root, "initial.txt"), "hello\n")
          System.cmd("git", ["-C", test_root, "add", "."])
          System.cmd("git", ["-C", test_root, "commit", "-m", "initial"])

          since = DateTime.add(DateTime.utc_now(), -3600, :second)

          File.write!(Path.join(test_root, "modified.txt"), "changed\n")

          assert {:active, mtime} = WorkspaceActivity.scan_workspace_activity(test_root, since)
          assert %DateTime{} = mtime
          assert DateTime.compare(mtime, since) in [:gt, :eq]
        after
          File.rm_rf(test_root)
        end
      else
        IO.puts(:stderr, "SKIP: git not available in PATH")
      end
    end

    test "git repo with no recent modifications returns {:stale, nil}" do
      if git_available?() do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-wa-git-stale-#{System.unique_integer([:positive])}"
          )

        try do
          File.mkdir_p!(test_root)
          System.cmd("git", ["init", "-b", "main"], cd: test_root)
          System.cmd("git", ["-C", test_root, "config", "user.name", "Test User"])
          System.cmd("git", ["-C", test_root, "config", "user.email", "test@example.com"])

          File.write!(Path.join(test_root, "file.txt"), "hello\n")
          System.cmd("git", ["-C", test_root, "add", "."])
          System.cmd("git", ["-C", test_root, "commit", "-m", "initial"])

          future = DateTime.add(DateTime.utc_now(), 3600, :second)
          assert {:stale, nil} = WorkspaceActivity.scan_workspace_activity(test_root, future)
        after
          File.rm_rf(test_root)
        end
      else
        IO.puts(:stderr, "SKIP: git not available in PATH")
      end
    end

    test "non-git directory with recently modified file returns {:active, datetime}" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-wa-nongit-active-#{System.unique_integer([:positive])}"
        )

      try do
        File.mkdir_p!(test_root)

        since = DateTime.add(DateTime.utc_now(), -3600, :second)

        File.write!(Path.join(test_root, "plain.txt"), "not git\n")

        assert {:active, mtime} = WorkspaceActivity.scan_workspace_activity(test_root, since)
        assert %DateTime{} = mtime
      after
        File.rm_rf(test_root)
      end
    end

    test "skips node_modules, _build, deps, .elixir_ls in non-git scan" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-wa-skip-#{System.unique_integer([:positive])}"
        )

      try do
        File.mkdir_p!(Path.join([test_root, "node_modules", "pkg"]))
        File.mkdir_p!(Path.join(test_root, "_build"))
        File.mkdir_p!(Path.join([test_root, "deps", "lib"]))
        File.mkdir_p!(Path.join(test_root, ".elixir_ls"))

        File.write!(Path.join([test_root, "node_modules", "pkg", "index.js"]), "skip\n")
        File.write!(Path.join([test_root, "_build", "app.beam"]), "skip\n")
        File.write!(Path.join([test_root, "deps", "lib", "dep.ex"]), "skip\n")
        File.write!(Path.join([test_root, ".elixir_ls", "config.json"]), "skip\n")

        assert {:stale, nil} = WorkspaceActivity.scan_workspace_activity(test_root, nil)
      after
        File.rm_rf(test_root)
      end
    end

    test "git repo with clean working tree returns {:stale, nil} regardless of since" do
      if git_available?() do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-wa-clean-#{System.unique_integer([:positive])}"
          )

        try do
          File.mkdir_p!(test_root)
          System.cmd("git", ["init", "-b", "main"], cd: test_root)
          System.cmd("git", ["-C", test_root, "config", "user.name", "Test User"])
          System.cmd("git", ["-C", test_root, "config", "user.email", "test@example.com"])

          File.write!(Path.join(test_root, "committed.txt"), "hello\n")
          System.cmd("git", ["-C", test_root, "add", "."])
          System.cmd("git", ["-C", test_root, "commit", "-m", "initial"])

          assert {:stale, nil} = WorkspaceActivity.scan_workspace_activity(test_root, nil)

          past = DateTime.add(DateTime.utc_now(), -3600, :second)
          assert {:stale, nil} = WorkspaceActivity.scan_workspace_activity(test_root, past)
        after
          File.rm_rf(test_root)
        end
      else
        IO.puts(:stderr, "SKIP: git not available in PATH")
      end
    end
  end

  describe "last_activity_mtime/2" do
    test "returns nil for nil workspace_path" do
      assert nil == WorkspaceActivity.last_activity_mtime(nil, nil)
    end

    test "returns nil for non-existent path" do
      missing =
        Path.join(
          System.tmp_dir!(),
          "symphony-wa-mtime-missing-#{System.unique_integer([:positive])}"
        )

      assert nil == WorkspaceActivity.last_activity_mtime(missing, nil)
    end

    test "returns most recent mtime for git repo with modified files" do
      if git_available?() do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-wa-mtime-git-#{System.unique_integer([:positive])}"
          )

        try do
          File.mkdir_p!(test_root)
          System.cmd("git", ["init", "-b", "main"], cd: test_root)
          System.cmd("git", ["-C", test_root, "config", "user.name", "Test User"])
          System.cmd("git", ["-C", test_root, "config", "user.email", "test@example.com"])

          File.write!(Path.join(test_root, "initial.txt"), "hello\n")
          System.cmd("git", ["-C", test_root, "add", "."])
          System.cmd("git", ["-C", test_root, "commit", "-m", "initial"])

          File.write!(Path.join(test_root, "a.txt"), "a\n")
          File.write!(Path.join(test_root, "b.txt"), "b\n")

          mtime = WorkspaceActivity.last_activity_mtime(test_root, nil)
          assert %DateTime{} = mtime
        after
          File.rm_rf(test_root)
        end
      else
        IO.puts(:stderr, "SKIP: git not available in PATH")
      end
    end

    test "returns nil for non-git directory with only skipped dirs" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-wa-mtime-skip-#{System.unique_integer([:positive])}"
        )

      try do
        File.mkdir_p!(Path.join([test_root, "node_modules", "pkg"]))
        File.write!(Path.join([test_root, "node_modules", "pkg", "index.js"]), "skip\n")

        assert nil == WorkspaceActivity.last_activity_mtime(test_root, nil)
      after
        File.rm_rf(test_root)
      end
    end
  end
end

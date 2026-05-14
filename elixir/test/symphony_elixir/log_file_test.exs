defmodule SymphonyElixir.LogFileTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.LogFile

  test "default_log_file/0 uses the current working directory" do
    assert LogFile.default_log_file() == Path.join(File.cwd!(), "log/symphony.log")
  end

  test "default_log_file/1 builds the log path under a custom root" do
    root = Path.join(System.tmp_dir!(), "symphony-logs")
    assert LogFile.default_log_file(root) == Path.join(root, "log/symphony.log")
  end
end

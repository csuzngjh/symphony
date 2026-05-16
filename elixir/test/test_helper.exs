target = System.get_env("TEST_TARGET", "local")

# Default: use fake ACPX for fast, deterministic tests.
# Real ACPX/Claude smoke tests require explicit opt-in.
fake_acpx_js = Path.join(__DIR__, "fixtures/fake_acpx.js")
use_real_acpx = System.get_env("SYMPHONY_USE_FAKE_ACPX") == "false"

if use_real_acpx do
  # Real ACPX: restore any previous override and let AcpxCli find it on PATH
  if original = System.get_env("ACPX_COMMAND_ORIGINAL") do
    System.put_env("ACPX_COMMAND", original)
    System.delete_env("ACPX_COMMAND_ORIGINAL")
  else
    System.delete_env("ACPX_COMMAND")
  end
else
  # Point ACPX at the local fake harness via ACPX_COMMAND.
  # AcpxCli.resolve_strategy sees .js → {:node_js, node, path} automatically.
  # Save any existing value so real-agent test overrides can restore it later.
  if existing = System.get_env("ACPX_COMMAND") do
    System.put_env("ACPX_COMMAND_ORIGINAL", existing)
  end
  # Four modes controlled by FAKE_ACPX_MODE env var: success | hang | write_then_hang | fail
  System.put_env("ACPX_COMMAND", fake_acpx_js)
end

if target == "local" do
  Application.put_env(:symphony_elixir, SymphonyElixir.AgentRunner,
    acpx_path: "acpx"
  )
else
  Application.put_env(:symphony_elixir, SymphonyElixir.AgentRunner,
    acpx_path: "/app/node_modules/.bin/acpx"
  )
end

# ExUnit tag configuration:
#
#  :real_agent  — tests that spawn a real ACPX/Claude process.
#                 Excluded by default; run with:
#                   SYMPHONY_USE_FAKE_ACPX=false mix test --include real_agent
#
#  :integration — tests that spin up real in-process sessions (fake ACPX,
#                 no external services).  Included by default; skip with:
#                   mix test --exclude integration
#
#  :live_e2e    — tests requiring Linear + Docker + Codex.  Skipped unless
#                   SYMPHONY_RUN_LIVE_E2E=1

# Exclude real_agent tests by default so `mix test` never hits real Claude
ExUnit.configure(exclude: [:real_agent])

ExUnit.start()

Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
# Testing Guide

## Test Tiers

Symphony tests are split into tiers so `mix test` is fast, deterministic, and never touches real external services.

| Tier | Tag | Default | What it hits |
|------|-----|---------|--------------|
| Unit | _(none)_ | **included** | Pure logic, mocks |
| Integration | `@tag :integration` | **included** | In-process sessions with fake ACPX |
| Real Agent | `@tag :real_agent` | **excluded** | Real ACPX/Claude subprocess |
| Live E2E | `@tag :live_e2e` | **excluded** | Linear API + Docker + Codex |

## Quick Reference

```sh
# Fast deterministic suite (no network, no real agent)
mix test

# Skip integration tests (pure unit only)
mix test --exclude integration

# Real ACPX/Claude smoke tests (requires ACPX installed + API key)
SYMPHONY_USE_FAKE_ACPX=false mix test --include real_agent

# Live E2E (requires full environment)
SYMPHONY_RUN_LIVE_E2E=1 mix test --include live_e2e
```

## Fake ACPX Harness

`test/fixtures/fake_acpx.js` is a Node.js script that mimics the ACPX CLI JSON-RPC 2.0 output. The test helper sets `ACPX_COMMAND` to this fixture by default.

### Modes

Controlled by `FAKE_ACPX_MODE` env var:

| Mode | Behavior |
|------|----------|
| `success` (default) | Emits full session lifecycle: thought chunks, message chunks, tool call/result, usage, then end_turn |
| `fail` | Exits with code 1 immediately |
| `hang` | Emits one event then sleeps (for stall/timeout testing) |
| `write_then_hang` | Emits partial output then sleeps (for partial-read testing) |

### How It Works

1. `test_helper.exs` sets `ACPX_COMMAND` to `test/fixtures/fake_acpx.js` before tests start.
2. `AcpxCli.resolve_strategy/3` sees the `.js` extension and routes it through `{:node_js, node, path}`.
3. The fake ACPX emits JSON-RPC 2.0 messages that `EventParser` handles identically to real ACPX output.
4. Setting `SYMPHONY_USE_FAKE_ACPX=false` restores the original `ACPX_COMMAND` (or clears it) so real ACPX is used.

### Adding Tests

For new tests that exercise the agent runner pipeline without real external services, use the fake ACPX (it is the default). No special setup needed.

For tests that must validate real Claude behavior, tag them:

```elixir
@tag :real_agent
test "real agent completes a task" do
  # ...
end
```

# Symphony

Elixir agent orchestration service that polls Linear, creates per-issue workspaces, and runs coding agents via ACPX.

## Project Structure

```
symphony/
├── SPEC.md              # Architecture specification (source of truth)
├── HANDOFF.md          # Current state, known issues, next steps
├── WORKFLOW.smoke.yaml # Smoke test configuration
├── .github/            # CI workflows
├── .codex/skills/      # Codex agent skills (linear, land, commit, debug, push, pull)
└── elixir/            # Main Elixir application
    ├── lib/            # Source code (GenServer orchestration)
    ├── test/           # ExUnit tests
    ├── AGENTS.md       # Elixir-specific conventions (READ THIS FIRST for elixir/ work)
    ├── WORKFLOW.md     # Default workflow config (YAML front matter + prompt template)
    └── mix.exs         # Elixir project definition
```

## Key Reference Documents

| Document | Purpose |
|----------|---------|
| `SPEC.md` | Architecture, state machine, protocol contracts |
| `HANDOFF.md` | Current implementation state, known P0/P1 issues |
| `elixir/AGENTS.md` | Elixir code conventions, test rules, PR requirements |
| `elixir/WORKFLOW.md` | Default workflow config + agent prompt template |

## WHERE TO LOOK

| Task | Location |
|------|----------|
| Orchestrator GenServer | `elixir/lib/symphony_elixir/orchestrator.ex` |
| Agent Runner (worker) | `elixir/lib/symphony_elixir/agent_runner.ex` |
| ACPX Session | `elixir/lib/symphony_elixir/agent_runner/acpx_session.ex` |
| Workspace Management | `elixir/lib/symphony_elixir/workspace.ex` |
| Config Schema | `elixir/lib/symphony_elixir/config/schema.ex` |
| Linear Adapter | `elixir/lib/symphony_elixir/linear/` |

## Architecture (from SPEC.md)

```
Orchestrator (poll tick)
 └─ maybe_dispatch()
      └─ choose_issues()
           └─ dispatch_issue()
                └─ AgentRunner.run()
                     ├─ Workspace.create_for_issue()
                     ├─ run_codex_turns()
                     │    ├─ AcpxSession.start_link()
                     │    ├─ AcpxSession.sessions_ensure()
                     │    ├─ [loop] AcpxSession.prompt()
                     │    └─ AcpxSession.sessions_close()
                     └─ [fallback] AcpxSession.exec()
```

## Agent Integration

- **Current backend**: ACPX CLI (`claude-agent-acp`) via `AcpxSession` GenServer
- **Legacy backend**: Codex AppServer stdio (retained but not used)
- **Workflow config**: YAML front matter in `WORKFLOW.md` parsed by `Config.Schema`

## Dev Commands

```bash
# Elixir app
cd elixir
mix setup           # Install dependencies
mix test            # Run tests
make all           # Full quality gate (format + lint + coverage + dialyzer)

# Smoke test (requires Linear API token)
mix test test/symphony_elixir/symphony_smoke_safety_test.exs
```

## Important Constraints

- Workspace safety: Never run agent cwd in source repo
- Workspaces must stay under configured workspace root
- Orchestrator is stateful/concurrent-sensitive; preserve retry/reconciliation semantics
- All `lib/` public functions must have `@spec` (enforced by `mix specs.check`)

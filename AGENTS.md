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

## PART II: 12 Behavioral Rules for AI Engineering

### Rule 1 — Think Before Coding
State assumptions explicitly. If uncertain, ask rather than guess.
Present multiple interpretations when ambiguity exists.
Push back when a simpler approach exists. Stop when confused. Name what's unclear.

### Rule 2 — Simplicity First
Minimum code that solves the problem. Nothing speculative.
No features beyond what was asked. No abstractions for single-use code.
Test: would a senior engineer say this is overcomplicated? If yes, simplify.

### Rule 3 — Surgical Changes
Touch only what you must. Clean up only your own mess.
Don't "improve" adjacent code, comments, or formatting.
Don't refactor what isn't broken. Match existing style.

### Rule 4 — Goal-Driven Execution
Define success criteria. Loop until verified.
Don't follow steps. Define success and iterate.
Strong success criteria let you loop independently.

### Rule 5 — Use the model only for judgment calls (Code > Prompt)
Use LLMs for: classification, drafting, summarization, extraction.
Do NOT use LLMs for: routing, retries, deterministic transforms.
**PD Specific**: If it can be a hard L2 Rule (Code), don't make it a soft L1 Principle (Prompt). If code can answer, code answers.

### Rule 6 — Respect Context Budgets (Context Pressure)
Per-task: 4,000 tokens. Per-session: 30,000 tokens.
**PD Specific**: Beware of "Complexity Damping" (L1 bloat). If approaching context budget or if the System Prompt is getting too large, summarize, prune, and start fresh. Do not silently overrun.

### Rule 7 — Surface conflicts, don't average them
If two patterns contradict, pick one (more recent / more tested).
Explain why. Flag the other for cleanup. Don't blend conflicting patterns.

### Rule 8 — Read before you write
Before adding code, read exports, immediate callers, shared utilities.
"Looks orthogonal" is dangerous. If unsure why code is structured a way, ask.

### Rule 9 — Tests verify intent, not just behavior
Tests must encode WHY behavior matters, not just WHAT it does.
A test that can't fail when business logic changes is wrong.
**PD Specific**: New L2 Rules must pass "Offline Replay Tests" against historical pain trajectories.

### Rule 10 — Checkpoint after every significant step
Summarize what was done, what's verified, what's left.
Don't continue from a state you can't describe back. If you lose track, stop and restate.

### Rule 11 — Match the codebase's conventions, even if you disagree
Conformance > taste inside the codebase.
If you genuinely think a convention is harmful, surface it via an ADR (Architecture Decision Record). Don't fork silently.

### Rule 12 — Fail loud
"Completed" is wrong if anything was skipped silently.
"Tests pass" is wrong if any were skipped.
Default to surfacing uncertainty, not hiding it. 

---
## 📚 Required Reading for Major Changes
If asked to make architectural changes, you MUST refer to:
1. `docs/architecture/DOMAIN_MODEL.md`
2. `docs/architecture-governance/AI_DEVELOPMENT_GUARDRAILS.md`
3. `docs/architecture/PD_SYSTEM_ARCHITECTURE.md`
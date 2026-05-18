---
# Symphony Self-Dispatch Workflow
#
# Routing contract:
# - Symphony platform issues live in Project S (slug: fc77e862278f)
#   and use this workflow.
# - PD issues live in Project P (slug: 67eb8e1d6bff) and use WORKFLOW.md
#   (the PD workflow).
# - A Symphony issue must NOT be dispatched by the PD workflow.
# - A PD issue must NOT be dispatched by this Symphony self workflow.
#
# Deploy this file as WORKFLOW.md (or reference it via -WorkflowPath)
# to run Symphony platform issues.
#
# NOTE: Do NOT commit real API keys to this file.
# Set LINEAR_API_KEY environment variable instead.

tracker:
  kind: linear
  api_key: "$LINEAR_API_KEY"
  project_slug: "fc77e862278f"  # Project S: Symphony Orchestrator Platform
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
  required_label: ready-for-agent
polling:
  interval_ms: 5000
workspace:
  root: D:/code/symphony-self-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/csuzngjh/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    echo "workspace cleanup for {{ issue.identifier }}"
agent:
  max_concurrent_agents: 10
  max_turns: -1
  model: "sonnet"
codex:
  agent: "claude"
  command: npx -y @agentclientprotocol/claude-agent-acp --app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

## Workspace Safety Contract

{% if workspace_path %}
- Worker workspace: {{ workspace_path }}
- Only operate inside this worker workspace. All file edits, tool calls, and commands must target paths within this workspace.
{% endif %}
{% if source_checkout_path %}
- Do NOT cd to {{ source_checkout_path }}. The source checkout is read-only reference, not your working directory.
- Do NOT edit files in {{ source_checkout_path }}.
{% endif %}

You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

## Branch and PR Flow

You are working on branch `{{ branch_name }}`. Do NOT create a new branch.

When your work is complete and tests pass:
1. Leave your final file changes in the workspace.
2. Do NOT run `git push`.
3. Do NOT run `gh pr create`.
4. Do NOT update Linear status.
5. Write `.symphony/agent-completion.json` exactly once with the completion report contract below.
6. Symphony will stage allowed files, commit, push, create the PR, and move Linear to In Review after validating the report.

Completion report contract:

```json
{
  "status": "ready_for_review",
  "changed_files": ["path/to/file.ext"],
  "tests": [{"command": "exact command", "result": "passed"}],
  "risks": ["known residual risk, or none"],
  "notes": "short implementation summary"
}
```

- Use `status: "ready_for_review"` only when code and tests are ready for PR.
- Use `status: "blocked"` when you cannot complete the issue; include the blocker in `notes`.
- `changed_files` must list only product/source/test/doc files you intentionally changed. Do not list `.symphony/agent-completion.json`.
- At least one test command is required. If no test can be run, write the reason in `tests[0].result`.

## Workflow

1. Determine the issue's current state, but do not change Linear status yourself.
2. Write a short plan in the workpad first:
   - What needs to be done
   - How to verify
   - What the impact is
3. Start implementing with focused changes and tests.
4. After each milestone, update the workpad.
5. When complete, write the completion report and stop. Symphony owns commit, push, PR creation, and Linear transition.

### State transitions
- `Todo` → Symphony starts work
- `In Progress` → implementation is underway
- `In Review` / `Human Review` → done, waiting for review
- `Merging` → review passed, agent may merge if explicitly dispatched for merge work
- `Rework` → needs changes
- `Done` → complete

### Principles
- Work autonomously, don't ask for next steps.
- If blocked by missing permissions/secrets, write `status: "blocked"` in `.symphony/agent-completion.json` and explain clearly in `notes`.
- Do not push, create PRs, or update Linear status.

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

## Workflow

1. Determine the issue's current state and follow the state transitions below
2. From `Todo`: immediately move to `In Progress` → create/find workpad comment
3. Write a plan in the workpad first:
   - What needs to be done
   - How to verify
   - What the impact is
4. Start implementing (code, tests, etc.)
5. After each milestone, update the workpad
6. When complete:
   - Create a PR, link it to the issue
   - Move to `Human Review` for review

### State transitions
- `Todo` → `In Progress`: start working
- `In Progress` → implementing
- `Human Review` → done, waiting for review
- `Merging` → review passed, agent merges
- `Rework` → needs changes
- `Done` → complete

### Principles
- Work autonomously, don't ask for next steps
- If blocked (missing permissions/secrets), write clearly in workpad
- Only move to `Human Review` when truly done
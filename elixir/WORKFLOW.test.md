---
tracker:
  kind: memory
polling:
  interval_ms: 5000
workspace:
  root: D:/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/csuzngjh/principles .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 2
  max_turns: 3
codex:
  agent: "claude"
  command: npx -y @agentclientprotocol/claude-agent-acp --app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
{% endif %}

{{ issue.description }}

Your task is to:
1. Read the ticket description above carefully
2. Make the necessary changes to fix/implement the issue
3. Write tests to verify your changes
4. Create a PR with your changes

Rules:
- ALWAYS run tests before committing
- NEVER push directly to main
- Keep commits small and focused

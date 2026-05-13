---
# Symphony ACPX/Claude Workflow - Trial Configuration
#
# This is a SAFE trial workflow for testing Symphony with real Linear issues.
# Safety guarantees:
# - max_concurrent_agents=1 (one issue at a time)
# - Process lifecycle enforced (process tree kill on stall/exit)
# - Attempt lock prevents concurrent attempts on same issue
# - Workspace dirty fail-closed prevents workspace corruption
# - stall_timeout visible in dashboard via phase tracking
#
# NOTE: Do NOT commit real API keys to this file.
# Set LINEAR_API_KEY environment variable instead.

tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "your-project-slug"
  active_states:
    - "Todo"
    - "In Progress"
  terminal_states:
    - "Closed"
    - "Cancelled"
    - "Canceled"
    - "Duplicate"
    - "Done"
  issue_identifiers:
    # Trial: only process this single issue
    - "PRI-117"

polling:
  interval_ms: 30000

workspace:
  root: "D:\\Code\\principles-workspaces"

agent:
  max_concurrent_agents: 1
  max_turns: -1
  continuation_retry_delay_ms: 300000
  max_retry_backoff_ms: 600000

codex:
  agent: claude
  command: claude
  turn_timeout_ms: 1800000
  stall_timeout_ms: 300000
  read_timeout_ms: 15000

hooks:
  after_create: "git clone --depth 1 https://github.com/your-org/your-repo.git ."
  before_run: "echo 'Starting agent run for issue {{ identifier }}'"
  after_run: "echo 'Agent run completed for issue {{ identifier }}'"
  timeout_ms: 60000

observability:
  enabled: true
  refresh_ms: 5000

server:
  port: 4001
  host: "127.0.0.1"
---
You are working on a Linear ticket `{{ issue.identifier }}`.

Issue context:
- Identifier: {{ issue.identifier }}
- Title: {{ issue.title }}
- Current status: {{ issue.state }}
- URL: {{ issue.url }}

{% if attempt > 0 -%}
This is retry attempt #{{ attempt }}. The previous attempt stalled or failed.
Focus on making progress this time — your workspace is in the same state as before.
{% endif -%}

This is an unattended orchestration session.
Work autonomously. Do not ask for user input.
Only stop early for a true blocker that prevents further progress.
When you believe the work is complete, run "exit 0" to finish the turn.

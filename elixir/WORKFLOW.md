---
tracker:
  kind: linear
  # project_slug: "d4fdb8223f27"  # 不设置 = 轮询整个团队下的所有项目
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
  dispatch_label: symphony
polling:
  interval_ms: 5000
workspace:
  root: D:/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/csuzngjh/principles . && (pnpm install 2>&1 || npm install 2>&1 || echo install skipped)
  before_remove: |
    echo "workspace cleanup for {{ issue.identifier }}"
agent:
  max_concurrent_agents: 10
  max_turns: -1
  model: "sonnet"
  # allowed_tools: []  # List of allowed tool names (empty = all tools)
  # prompt_retries: 0  # Retry failed prompts on transient errors
codex:
  agent: "claude"  # acpx agent: "claude", "opencode", "codex"
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

## Branch and PR Flow

You are working on branch `{{ branch_name }}`. Do NOT create a new branch.

When your work is complete and tests pass:
1. Leave your final file changes in the workspace.
2. Do NOT run `git push`.
3. Do NOT run `gh pr create`.
4. Do NOT update Linear status.
5. Symphony will stage allowed files, commit, push, create the PR, and move Linear to In Review.

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

## 语言和受众要求（重要）

所有 workpad 评论、状态描述、摘要、更新——全部必须用**中文**。受众是**产品经理、项目经理、业务人员**，不是开发者。

每次更新 workpad 时，必须包含以下结构的完整内容（不要只写技术细节）：

### 业务摘要（必须）

```
### 业务摘要

#### 做了什么
[用一句话说清楚这次完成了什么功能/修复]

#### 为什么这么做
[业务层面的原因，不说技术细节]

#### 改了哪些东西（对业务人员来说）
- 新增/修改了哪个页面、哪个功能
- 用户操作流程有什么变化
- 对现有功能有什么影响

#### 怎么验收（非技术人员可操作）
1. 打开 [页面/功能] → 应该看到 [预期效果]
2. 点击/操作 [某个按钮/流程] → 应该 [预期行为]
3. [具体验证步骤，不需要命令行操作]
```

## 工作流程

### 状态流转
- `Backlog` → 不动，等人移到 Todo
- `Todo` → 开始干活；如果需要状态变更，由 Symphony 控制面处理
- `In Progress` → 正在实施中
- `In Review` / `Human Review` → 干完了，等我来评审
- `Merging` → 我确认通过，agent 执行合并
- `Rework` → 我要改，agent 重新改
- `Done` → 完成

### 执行步骤

1. 确定 issue 当前状态，按上述状态流转执行；不要自行修改 Linear 状态
2. 从 `Todo` 开始：创建/找到 workpad 评论
3. **先在 workpad 写计划**（用中文，面向业务人员）：
   - 要做什么
   - 怎么验证
   - 业务影响是什么
4. 开始实施（写代码、测试等）
5. **每完成一个里程碑**，更新 workpad 的业务摘要
6. 全部完成后：
   - 更新 workpad 最终版**业务摘要**
   - 停止在本地文件改动状态
   - 不要创建 PR，不要把 PR 链接贴到 issue 上，不要变更 issue 状态
   - Symphony 会提交、推送、创建 PR，并把 issue 变更为 `In Review`

### 评审阶段（In Review / Human Review）
- 我来看 workpad 的**业务摘要**和 PR
- 通过 → 我会变 `Merging`，agent 自动合并
- 要改 → 我变 `Rework`，agent 重新改

### 基本原则
- 自主完成所有工作，不要问我要下一步
- 卡住时（缺权限/密钥），在 workpad 写清楚卡在哪、需要我做什么
- 只在真正做完了才停手，等待 Symphony 创建 PR 和变更状态

## Workpad 模板

````md
## Codex Workpad

### 业务摘要

#### 做了什么
[一句话描述]

#### 为什么这么做
[业务原因]

#### 改了哪些东西
- [功能/页面变更描述]

#### 怎么验收
1. [验证步骤1]
2. [验证步骤2]

### 实施详情（技术参考）

#### 变更清单
- [ ] 任务 1
- [ ] 任务 2

#### 验证结果
- [ ] 测试通过

### 备注
- [进度记录]
````

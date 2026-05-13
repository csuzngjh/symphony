# Symphony Handoff

## Session Context

这是一个 Symphony 服务（Elixir GenServer 应用）的独立仓库 fork，从 `https://github.com/openai/symphony.git` fork 到 `https://github.com/csuzngjh/symphony`。

### 仓库状态

- **仓库路径**: `D:\Code\symphony`
- **当前分支**: `feat/acpx-integration`
- **最新提交**: `f9022f4 feat(symphony): migrate from Codex AppServer to acpx session mode`
- **相对于 origin/main**: 26 files changed, +3799 / -384

### 与 PD 项目的关系

Symphony 是独立的开源项目（OpenAI 出的 Codex agent orchestrator），不是 PD 项目的一部分。用户 fork 后准备深度修改并自用。原克隆在 `D:\Code\principles\symphony`（嵌套 git repo），已删除。PD 项目 `.gitignore` 已有 `/symphony/` 条目。

---

## 本轮已完成工作

### 从 Codex AppServer 迁移到 ACPX

上一轮 AI 助手完成了核心架构迁移：

1. **废弃了 Codex AppServer stdio 协议**（`app_server.ex` 保留但不再被 `agent_runner.ex` 调用）
2. **切换到 ACPX CLI** 作为 agent 执行后端
   - `acpx_session.ex` — GenServer 管理 acpx session 生命周期
   - `acpx_cli.ex` — 跨平台 ACPX CLI 策略解析（Windows shell 回退）
   - `acpx_runner.ex` — 参数构建/结果解析辅助
   - `event_parser.ex` — ACPX NDJSON streaming 事件解析
   - `shell_resolution.ex` — 跨平台 shell 命令解析

### 修复的问题

1. **不再启动 Codex** — 只走 `acpx -> claude-agent-acp -> claude.exe`
2. **修掉了 1 秒重试循环** — 新增 `agent.continuation_retry_delay_ms`，默认 300 秒
3. **修了 ACPX 失败输出丢失** — streaming 模式下 exit 非 0 时保留 raw output

### Smoke 验证

- `mix test test/symphony_elixir/symphony_smoke_safety_test.exs test/symphony_elixir/agent_runner/acpx_cli_test.exs test/symphony_elixir/agent_runner/acpx_session_test.exs test/symphony_elixir/core_test.exs:517` — 108 tests, 0 failures
- `WORKFLOW.smoke.yaml` 配置了单 worker (max_concurrent_agents: 1) + 单 turn (max_turns: 1) 的真实 issue PRI-117 端到端验证

---

## 架构概述（当前状态）

### 核心模块

| 模块 | 位置 | 职责 |
|------|------|------|
| `Orchestrator` | `orchestrator.ex` | GenServer 轮询 Linear，派发/重试/回收 issue |
| `AgentRunner` | `agent_runner.ex` | 单次 worker 执行：workspace → prompt → acpx session |
| `AcpxSession` | `agent_runner/acpx_session.ex` | 管理 ACPX CLI session 的 GenServer |
| `AcpxCli` | `agent_runner/acpx_cli.ex` | ACPX CLI 策略解析（direct / shell / node_js） |
| `EventParser` | `agent_runner/event_parser.ex` | 解析 ACPX NDJSON streaming 事件 |
| `Config.Schema` | `config/schema.ex` | WORKFLOW.md front matter typed schema |
| `Workspace` | `workspace.ex` | 工作区创建/清理/钩子 |

### 执行流程

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

### 已知问题（待修复）

**P0 — 影响正确性**

1. **AcpxSession 单例冲突** — `acpx_session.ex:53` 使用 `name: __MODULE__`，多 worker 并发时第二个会 crash。当前 `max_concurrent_agents: 1` 掩盖了这个问题。
2. **Port 泄漏** — `collect_output` timeout 路径没有调用 `clean_port`，子进程可能变成孤儿。
3. **Exec fallback 缺少 issue state refresh** — `do_run_acpx_turns_exec` 每轮后没有调用 `continue_with_issue?`，即使 issue done 了还会继续循环。

**P1 — 稳定性**

4. **错误分类缺失** — 不可重试错误（配置错误、权限拒绝）也在指数退避重试。
5. **缺少 Graceful Shutdown** — SIGTERM 时 running session 不会正确关闭。
6. **测试覆盖不足** — 没有 mock port 的集成测试、没有并发测试。

---

## 下阶段计划

### 切片 1（优先做）：AgentRunner 稳固化

合并三个紧密耦合的修复：

1. **AcpxSession 去单例化** — 去掉 `name: __MODULE__`，改 caller 传入 name，或使用 `:via` tuple。AgentRunner 每次 start_link 传唯一名
2. **Port 生命周期保障** — `collect_output` 所有 exit path（包括 timeout）统一 `clean_port`；考虑用 `Port.monitor` + `receive` 双路监听
3. **Exec fallback 补 `continue_with_issue?`** — 与 session 路径对称
4. **追加入门集成测试** — 2 worker 并发启动、port 泄漏检测

**关键文件**：
- `lib/symphony_elixir/agent_runner/acpx_session.ex`
- `lib/symphony_elixir/agent_runner.ex`
- `test/symphony_elixir/agent_runner/acpx_session_test.exs`

### 切片 2：错误分类 + 熔断器

- 定义 `PermanentError` / `TransientError` 枚举
- ACPX CLI 连续 5 次失败 → circuit open，10min half-open
- Orchestrator 收到 `:usage_error`、`:permission_denied`、`:acpx_cli_resolution_failed` 时停止 retry

### 切片 3：生命周期管理

- Graceful shutdown（SIGTERM → close sessions → 超时 terminate）
- Session 持久化（SQLite `active_sessions`）
- 自动恢复 + orphen 清理

### 切片 4：监控 + Guardrails

- Per-session Logger metadata
- Dashboard session 级面板
- Token budget / max wall clock

---

## 开发环境

```bash
# 工作目录
D:\Code\symphony

# 编译
cd elixir && mix setup

# 运行指定测试
mix test test/symphony_elixir/agent_runner/acpx_session_test.exs

# 全量质量门
make all

# Smoke 测试（需要 Linear API token）
mix test test/symphony_elixir/symphony_smoke_safety_test.exs
```

### 关键配置

- `WORKFLOW.smoke.yaml` — smoke 测试配置（单 worker / 单 turn / PRI-117 allowlist）
- `elixir/WORKFLOW.md` — 默认工作流配置（Codex AppServer 模式，迁移后用 ACPX 模式替代）

### 注意

- `elixir/` 下有本地 ELixir 编译产物（`erlang.exe` 等），已通过 `.gitignore` 排除
- 默认 `codex.command` 已从 `codex app-server` 改为 `claude`
- Windows 上用 `cmd /S /C acpx` shim 执行 acpx

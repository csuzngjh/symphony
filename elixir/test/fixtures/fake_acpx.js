#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
//
// fake_acpx.js — deterministic ACPX harness for Symphony tests.
//
// Emits JSON-RPC 2.0 messages matching acpx --format=json streaming output.
//
// Modes (FAKE_ACPX_MODE env var):
//   success  Emit structured result and exit 0  (default)
//   fail     Exit with code 1 immediately
//   hang     Sleep 3600s then exit 0 (simulates stall)
//
// CLI argument fallback: first positional arg is used as mode when
// FAKE_ACPX_MODE is not set (acpx subcommand name becomes the arg, so
// "sessions new" → sessions, "exec" → exec — only "hang"/"fail" match).

const envMode = process.env.FAKE_ACPX_MODE;
const argMode = process.argv[2];
const mode = envMode || (argMode === "hang" || argMode === "fail" ? argMode : "success");

const workspace = process.env.FAKE_ACPX_WORKSPACE || "";

function jrpc(method, params) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
}

function jrpcResult(id, result) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function sessionUpdate(sessionId, sessionUpdateType, data) {
  jrpc("session/update", {
    sessionId,
    update: { sessionUpdate: sessionUpdateType, ...data }
  });
}

async function runSuccess() {
  const sid = "fake-session-001";
  await sessionUpdate(sid, "session/new", {});
  await sessionUpdate(sid, "agent_thought_chunk", { content: "Thinking about the task..." });
  await sessionUpdate(sid, "agent_message_chunk", { content: "Hello from fake ACPX." });
  await sessionUpdate(sid, "tool_call", { id: "tool-1", name: "Write", input: { file_path: "fake-output.txt", content: "created by fake_acpx" } });
  await sessionUpdate(sid, "tool_result", { id: "tool-1", output: "ok" });
  await sessionUpdate(sid, "agent_message_chunk", { content: "Task completed by fake ACPX." });
  await sessionUpdate(sid, "usage_update", { inputTokens: 100, outputTokens: 50, totalTokens: 150 });
  jrpcResult(null, { status: "success", exitCode: 0, stopReason: "end_turn", usage: { inputTokens: 100, outputTokens: 50, totalTokens: 150 } });
}

async function runHang() {
  const sid = "fake-session-hang";
  await sessionUpdate(sid, "session/new", {});
  await sessionUpdate(sid, "agent_thought_chunk", { content: "Fake ACPX hanging forever..." });
  await sleep(3600 * 1000);
}

async function runFail() {
  // fail immediately with no output (port sees exit status 1)
  process.exit(1);
}

async function main() {
  switch (mode) {
    case "hang":    await runHang(); break;
    case "fail":    await runFail(); break;
    default:        await runSuccess(); break;
  }
}

main().catch((err) => {
  console.error(JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32603, message: err.message } }));
  process.exit(1);
});
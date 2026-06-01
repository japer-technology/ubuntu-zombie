#!/usr/bin/env node
// tests/fixtures/fake-pi-json.mjs
//
// A stand-in for the real `pi` CLI's `--mode json` output, used to
// exercise payload/agent/pi-mono-bridge.mjs end-to-end without needing
// `@earendil-works/pi-coding-agent` (or a live LLM) on the test host.
//
// It ignores its CLI arguments and emits a realistic AgentSession event
// stream on stdout — the same schema the real `pi --mode json` emits
// (session / agent_start / turn_start / message_* / tool_execution_* /
// turn_end / agent_end) — then exits 0.
//
// ZOMBIE_FAKE_PI_MODE selects the scenario:
//   "text"  (default) — a normal streamed assistant answer.
//   "error"           — a provider/connection error with no answer.
//
// Crucially, it does NOT read stdin: the real `pi --mode json` is a
// one-shot event stream, and the bridge must let it exit on stdin EOF
// rather than keeping the pipe open (the 120s-timeout regression).

function out(o) { process.stdout.write(JSON.stringify(o) + "\n"); }

const ANSWER = "Hello from the local model!";
const mode = process.env.ZOMBIE_FAKE_PI_MODE || "text";

const base = {
  api: "openai-completions",
  provider: "lmstudio",
  model: "local-model",
  usage: {},
};

out({ type: "session", version: 3, id: "fake", timestamp: new Date().toISOString(), cwd: process.cwd() });
out({ type: "agent_start" });
out({ type: "turn_start" });
out({ type: "message_start", message: { role: "user", content: [{ type: "text", text: "say hi" }], timestamp: Date.now() } });
out({ type: "message_end", message: { role: "user", content: [{ type: "text", text: "say hi" }], timestamp: Date.now() } });

function waitForStdinEof() {
  return new Promise((resolve) => {
    process.stdin.on("end", resolve);
    process.stdin.resume();
  });
}

if (mode === "error") {
  const err = { role: "assistant", content: [], ...base, stopReason: "error", errorMessage: "Connection error.", timestamp: Date.now() };
  out({ type: "message_start", message: err });
  out({ type: "message_end", message: err });
  out({ type: "turn_end", message: err, toolResults: [] });
  out({ type: "agent_end", messages: [err], willRetry: false });
  await waitForStdinEof();
  process.exit(0);
}

const asst = (text) => ({ role: "assistant", content: text ? [{ type: "text", text }] : [], ...base, stopReason: "stop", timestamp: Date.now() });

out({ type: "message_start", message: asst("") });
// A tool_execution pair the bridge must tolerate (log only) without
// re-dispatching it as a mediated tool_call.
out({ type: "tool_execution_start", toolCallId: "t1", toolName: "read", args: { path: "/etc/os-release" } });
out({ type: "tool_execution_end", toolCallId: "t1", toolName: "read", result: "NAME=Ubuntu", isError: false });
let acc = "";
for (const piece of ["Hello", " from", " the", " local", " model!"]) {
  acc += piece;
  out({ type: "message_update", message: asst(acc), assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: piece, partial: asst(acc) } });
}
out({ type: "message_end", message: asst(ANSWER) });
out({ type: "turn_end", message: asst(ANSWER), toolResults: [] });
out({ type: "agent_end", messages: [asst(ANSWER)], willRetry: false });
await waitForStdinEof();
process.exit(0)

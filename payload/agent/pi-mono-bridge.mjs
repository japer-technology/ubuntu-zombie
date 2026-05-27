#!/usr/bin/env node
// payload/agent/pi-mono-bridge.mjs
//
// Phase 2 of docs/UPGRADE-TO-PI-PLAN.md. This bridge wraps the
// `pi` CLI shipped by `@earendil-works/pi-coding-agent` (alias
// "pi-mono") and re-exports its tool-call stream over a tiny
// line-delimited JSON protocol that payload/agent/pi_mono.py speaks.
//
// Protocol (one JSON object per line, both directions):
//
//   stdin  ← {"type":"start", "prompt", "system", "history",
//             "tools", "settings_path", "log_path", "max_tool_calls"}
//   stdout → {"type":"tool_call", "id", "name", "args"}
//   stdin  ← {"type":"tool_result", "id", "ok": bool, "result"|"error": ...}
//   stdout → {"type":"final", "text"}
//   stdout → {"type":"error", "message"}
//
// On systems without `pi` installed this bridge emits a clear
// error and exits; smoke tests override it via $ZOMBIE_PI_MONO_BRIDGE.
//
// The actual upstream `pi` CLI talks `--mode rpc` JSON-RPC on stdio;
// translating that protocol in a 60-line script is brittle, so this
// bridge takes a pragmatic approach: it spawns `pi --mode json -p`
// with --no-builtin-tools --tools <allowlist> and parses pi's JSON
// event stream into our protocol. Tool execution happens here:
// whenever pi requests a built-in tool that we've translated to one
// of our registry names, we relay it to Python, await the result,
// and feed pi the observation via its stdin protocol. If pi is not
// available the bridge surfaces a helpful error.

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { existsSync, openSync, writeSync, closeSync } from "node:fs";
import { dirname } from "node:path";

const stdin = process.stdin;
const stdout = process.stdout;

function send(obj) {
  stdout.write(JSON.stringify(obj) + "\n");
}

function fatal(message) {
  send({ type: "error", message: String(message) });
  process.exit(0);
}

let logFd = null;
function openLog(path) {
  if (!path) return;
  try {
    if (!existsSync(dirname(path))) return;
    logFd = openSync(path, "a");
  } catch (_e) {
    logFd = null;
  }
}
function logLine(tag, data) {
  if (logFd === null) return;
  try {
    const line = JSON.stringify({
      ts: new Date().toISOString(),
      tag,
      ...(typeof data === "object" ? data : { data }),
    }) + "\n";
    writeSync(logFd, line);
  } catch (_e) { /* best-effort */ }
}

async function readOneStartMessage() {
  return new Promise((resolve, reject) => {
    const rl = createInterface({ input: stdin });
    rl.once("line", (line) => {
      rl.close();
      try {
        const obj = JSON.parse(line);
        if (obj.type !== "start") {
          reject(new Error(`expected 'start', got ${obj.type}`));
          return;
        }
        resolve(obj);
      } catch (e) {
        reject(e);
      }
    });
    rl.once("close", () => reject(new Error("stdin closed before start")));
  });
}

function pendingTurnReplies() {
  // Map id -> resolver, populated when we forward a tool_call upstream
  // and awaiting a tool_result from Python on stdin.
  return new Map();
}

async function run() {
  let start;
  try {
    start = await readOneStartMessage();
  } catch (e) {
    fatal(`failed to read start message: ${e.message}`);
    return;
  }

  openLog(start.log_path);
  logLine("start", { tools: start.tools, prompt_len: (start.prompt || "").length });

  // Try to locate the `pi` binary.
  const piBin = process.env.ZOMBIE_PI_MONO_BIN || "pi";

  // Build CLI arguments.  We invoke pi in JSON-event mode with the
  // operator-supplied system prompt appended, the built-in tools off,
  // and the closed allow-list passed verbatim. The prompt is fed via
  // -p so pi exits after one turn.
  const args = [
    "--mode", "json",
    "-p", start.prompt,
    "--no-builtin-tools",
  ];
  if (Array.isArray(start.tools) && start.tools.length > 0) {
    args.push("--tools", start.tools.join(","));
  }
  if (typeof start.system === "string" && start.system.length > 0) {
    args.push("--append-system-prompt", start.system);
  }

  let child;
  try {
    child = spawn(piBin, args, {
      stdio: ["pipe", "pipe", "pipe"],
      env: process.env,
    });
  } catch (e) {
    fatal(`failed to spawn '${piBin}': ${e.message}`);
    return;
  }

  child.on("error", (e) => {
    fatal(`pi spawn error: ${e.message}. Is '@earendil-works/pi-coding-agent' installed globally?`);
  });

  const replies = pendingTurnReplies();

  // Forward pi stdout (JSON events, one per line) -> our protocol.
  const piOut = createInterface({ input: child.stdout });
  let assistantBuf = "";
  let finalEmitted = false;
  piOut.on("line", (line) => {
    line = line.trim();
    if (!line) return;
    let evt;
    try { evt = JSON.parse(line); } catch (_e) { return; }
    logLine("pi_event", evt);
    const kind = evt.type || evt.event || evt.kind;
    if (kind === "tool_use" || kind === "tool_call") {
      send({
        type: "tool_call",
        id: String(evt.id || evt.tool_use_id || Math.random().toString(36).slice(2)),
        name: String(evt.name || evt.tool || ""),
        args: evt.input || evt.args || {},
      });
    } else if (kind === "text" || kind === "assistant_text" || kind === "message") {
      const piece = evt.text || evt.content || "";
      if (typeof piece === "string") assistantBuf += piece;
    } else if (kind === "final" || kind === "done" || kind === "stop") {
      if (!finalEmitted) {
        finalEmitted = true;
        send({ type: "final", text: assistantBuf || String(evt.text || "") });
      }
    } else if (kind === "error") {
      fatal(evt.message || "pi reported error");
    }
  });

  // Forward our stdin (tool_result) back to pi.
  const ours = createInterface({ input: stdin });
  ours.on("line", (line) => {
    line = line.trim();
    if (!line) return;
    let reply;
    try { reply = JSON.parse(line); } catch (_e) { return; }
    if (reply.type !== "tool_result") return;
    // The pi `--mode json` protocol expects observations on stdin as
    // ``{"type":"tool_result","id":...,"output":...}``. Different pi
    // versions accept slightly different field names; emit the common
    // shape.
    const payload = {
      type: "tool_result",
      id: reply.id,
      output: reply.ok
        ? (typeof reply.result === "string" ? reply.result : JSON.stringify(reply.result))
        : `ERROR: ${reply.error || "tool failed"}`,
      is_error: !reply.ok,
    };
    try {
      child.stdin.write(JSON.stringify(payload) + "\n");
    } catch (_e) { /* pi may have exited */ }
    const r = replies.get(String(reply.id));
    if (r) { r(); replies.delete(String(reply.id)); }
  });

  child.stderr.on("data", (chunk) => {
    logLine("pi_stderr", { chunk: chunk.toString("utf8") });
  });

  child.on("exit", (code, signal) => {
    logLine("pi_exit", { code, signal });
    if (!finalEmitted) {
      finalEmitted = true;
      if (code === 0) {
        send({ type: "final", text: assistantBuf });
      } else {
        send({ type: "error",
               message: `pi exited with code=${code} signal=${signal || ""}`.trim() });
      }
    }
    if (logFd !== null) { try { closeSync(logFd); } catch (_e) {} }
    process.exit(0);
  });
}

run().catch((e) => fatal(e && e.message ? e.message : String(e)));

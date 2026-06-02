#!/usr/bin/env node
// payload/agent/pi-mono-bridge.mjs
//
// Wraps the `pi` CLI shipped by `@earendil-works/pi-coding-agent`
// (alias "pi-mono") and re-exports its tool-call stream over a tiny
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
// with pi's real built-in tools (read, bash, edit, write, grep, find,
// ls) enabled and parses pi's JSON event stream into our protocol. The
// whole prompt — rendered with the prior conversation so the agent has
// cross-turn memory — is supplied up front via `-p`, so `pi` needs no
// stdin; we spawn it with stdin closed (EOF) so it exits as soon as the
// turn finishes. (`pi --mode json` is a one-shot event *stream* —
// unlike `--mode rpc` it does not read tool observations back from
// stdin, so leaving stdin open just makes `pi` wait forever for EOF and
// never exit.) We parse `pi`'s real `--mode json` event schema (session
// / agent_start / turn_start / message_start / message_update /
// message_end / turn_end / agent_end / tool_execution_* / auto_retry_*)
// and surface the assistant's text — and any provider error — back to
// Python. If pi is not available the bridge surfaces a helpful error.

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
  // Exit non-zero so the supervising service / Python driver can tell a
  // reported failure apart from a clean shutdown.
  process.exit(1);
}

// Extract the plain assistant text from a `pi` message `content` array.
// Content is an ordered list of parts; we keep only `text` parts and
// drop `thinking` / `toolCall` parts (and tolerate a bare string).
function extractText(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  let out = "";
  for (const part of content) {
    if (part && part.type === "text" && typeof part.text === "string") {
      out += part.text;
    }
  }
  return out;
}

// pi's real built-in tool names (see `pi --help`: "Built-in tools:
// read, bash, edit, write, grep, find, ls"). The Python registry uses
// logical names like `fs.read` / `shell.run` that pi does not know
// about; forwarding those verbatim to `--tools` *and* passing
// `--no-builtin-tools` left the agent with zero usable tools, so it
// could not run anything and instead emitted tool-call-shaped text
// (e.g. `<|tool_call>call:fs.list{…}`). Enabling pi's genuine built-in
// tools lets the agent actually act on the operator's requests.
const PI_BUILTIN_TOOLS = ["read", "bash", "edit", "write", "grep", "find", "ls"];

// Render the prior conversation into the one-shot `-p` prompt so the
// agent has memory across turns. `pi --mode json -p` is a single-shot
// invocation with no session loaded, so without this the model never
// sees earlier turns and "forgets" names and context. The Python
// server appends the current user turn to `history` before sending, so
// the final entry usually duplicates `prompt`; drop it to avoid asking
// the current question twice.
function buildPrompt(start) {
  const prompt = start && start.prompt != null ? String(start.prompt) : "";
  const history = Array.isArray(start && start.history)
    ? start.history.slice()
    : [];
  if (history.length > 0) {
    const last = history[history.length - 1];
    if (last && last.role === "user" &&
        String(last.content != null ? last.content : "") === prompt) {
      history.pop();
    }
  }
  const lines = [];
  for (const m of history) {
    if (!m || typeof m !== "object") continue;
    const role = m.role === "assistant"
      ? "Assistant"
      : m.role === "user" ? "User" : null;
    if (!role) continue;
    lines.push(`${role}: ${m.content != null ? String(m.content) : ""}`);
  }
  if (lines.length === 0) return prompt;
  return "Conversation so far:\n" + lines.join("\n") +
    "\n\nCurrent message:\n" + prompt;
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
    const onClose = () => reject(new Error("stdin closed before start"));
    rl.once("line", (line) => {
      // Detach the close listener *before* calling rl.close() so the
      // synchronous "close" event it emits cannot race ahead of our
      // resolve/reject below — readline emits "line" then "close"
      // synchronously on rl.close(), and a "close" reject would
      // otherwise win against a later resolve (Promise resolution is
      // first-wins) and surface as a spurious
      // "stdin closed before start" error to the Python driver.
      rl.off("close", onClose);
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
    rl.once("close", onClose);
  });
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
  // operator-supplied system prompt appended and pi's real built-in
  // tools enabled. The prompt — rendered with the prior conversation so
  // the agent has memory — is fed via -p so pi exits after one turn.
  const args = [
    "--mode", "json",
    "-p", buildPrompt(start),
  ];
  // Model + provider come from payload/agent/providers.py (resolved
  // from /opt/ai-zombie/secrets/env) so the agent loop selects the
  // same model the chat banner advertises instead of pi's built-in
  // default ("google"). Both are optional: when unset the operator has
  // no provider configured and we let pi resolve credentials/model
  // from its own config (e.g. an OAuth subscription via `pi /login`).
  // The active provider's API key is already the only provider key in
  // our environment (pi_mono.py strips the rest), so pi authenticates
  // against exactly this provider via the standard env var.
  if (typeof start.provider === "string" && start.provider.length > 0) {
    args.push("--provider", start.provider);
  }
  if (typeof start.model === "string" && start.model.length > 0) {
    args.push("--model", start.model);
  }
  if (Array.isArray(start.tools) && start.tools.length > 0) {
    // The operator configured a tool allow-list, but its logical names
    // (fs.read, shell.run, …) are not pi tool ids. Enable pi's real
    // built-in tools so the agent can read the filesystem and run
    // commands; pi executes them itself in --mode json.
    args.push("--tools", PI_BUILTIN_TOOLS.join(","));
  }
  if (typeof start.system === "string" && start.system.length > 0) {
    args.push("--append-system-prompt", start.system);
  }

  let child;
  try {
    child = spawn(piBin, args, {
      // stdin is closed ("ignore") so `pi` receives EOF immediately and
      // exits once the `-p` turn completes. `pi --mode json` never reads
      // tool observations from stdin (that is `--mode rpc`), so an open
      // stdin pipe would only make `pi` hang waiting for EOF — which the
      // Python idle watchdog then reports as a spurious turn timeout.
      stdio: ["ignore", "pipe", "pipe"],
      env: process.env,
    });
  } catch (e) {
    fatal(`failed to spawn '${piBin}': ${e.message}`);
    return;
  }

  child.on("error", (e) => {
    fatal(`pi spawn error: ${e.message}. Is '@earendil-works/pi-coding-agent' installed globally?`);
  });

  // Idle watchdog (defence in depth). The Python driver already imposes
  // a per-turn idle deadline, but when this bridge is exercised
  // standalone — or if the driver is wedged — kill a `pi` child that has
  // gone silent (e.g. a hung provider socket) so we never block forever.
  // Disabled when ZOMBIE_PI_MONO_IDLE_TIMEOUT <= 0.
  const idleTimeoutMs = (() => {
    const raw = Number(process.env.ZOMBIE_PI_MONO_IDLE_TIMEOUT);
    if (Number.isFinite(raw)) return raw * 1000;
    return 150 * 1000; // generous: longer than the Python-side default
  })();
  let idleTimer = null;
  function clearIdle() {
    if (idleTimer !== null) { clearTimeout(idleTimer); idleTimer = null; }
  }
  function armIdle() {
    if (idleTimeoutMs <= 0) return;
    clearIdle();
    idleTimer = setTimeout(() => {
      logLine("idle_timeout", { ms: idleTimeoutMs });
      try { child.kill("SIGKILL"); } catch (_e) { /* already gone */ }
      if (!finalEmitted) {
        finalEmitted = true;
        fatal(`pi produced no output for ${Math.round(idleTimeoutMs / 1000)}s; terminated`);
      }
    }, idleTimeoutMs);
    if (typeof idleTimer.unref === "function") idleTimer.unref();
  }

  // Forward pi stdout (JSON events, one per line) -> our protocol.
  //
  // `pi --mode json` serialises every AgentSession event as one JSON
  // object per line. We translate the subset we care about:
  //
  //   * assistant text  — accumulated from `message_update`
  //     (`assistantMessageEvent.type === "text_delta"`) and finalised
  //     from the assistant `message_end` content parts.
  //   * provider errors — an assistant message with
  //     `stopReason === "error"` carries a human-readable `errorMessage`.
  //   * turn completion — the terminal `agent_end` (`willRetry !== true`)
  //     ends the turn; `pi` then exits because its stdin is closed.
  //
  // `pi` runs its own built-in tools in this mode (there is no stdin
  // observation channel like `--mode rpc`), so we only *log* any
  // `tool_execution_*` events rather than re-dispatching them through
  // Python — re-dispatching would double-execute and the model would
  // never see Python's result anyway.
  const piOut = createInterface({ input: child.stdout });
  let assistantText = "";   // latest successful assistant answer
  let lastError = "";       // latest provider/assistant error message
  let finalEmitted = false;

  function finish() {
    if (finalEmitted) return;
    finalEmitted = true;
    clearIdle();
    if (assistantText) {
      send({ type: "final", text: assistantText });
    } else if (lastError) {
      send({ type: "error", message: lastError });
    } else {
      send({ type: "final", text: "" });
    }
  }

  armIdle();
  piOut.on("line", (line) => {
    armIdle();
    line = line.trim();
    if (!line) return;
    let evt;
    try { evt = JSON.parse(line); } catch (_e) { return; }
    logLine("pi_event", evt);
    const kind = evt.type || evt.event || evt.kind;

    if (kind === "message_update") {
      // Incremental assistant text; accumulate the streamed deltas.
      const ame = evt.assistantMessageEvent;
      if (ame && ame.type === "text_delta" && typeof ame.delta === "string") {
        assistantText += ame.delta;
      }
    } else if (kind === "message_end") {
      const msg = evt.message;
      if (msg && msg.role === "assistant") {
        if (msg.stopReason === "error") {
          lastError = String(msg.errorMessage || "Provider error (no message)");
        } else {
          // Prefer the complete content from the finalised message so we
          // are robust even if individual deltas were missed.
          const txt = extractText(msg.content);
          if (txt) { assistantText = txt; lastError = ""; }
        }
      }
    } else if (kind === "tool_execution_start" || kind === "tool_execution_end") {
      // pi executes its own tools in --mode json; log for diagnostics only.
      logLine("pi_tool", { kind, name: evt.toolName, id: evt.toolCallId });
    } else if (kind === "agent_end") {
      // `willRetry === true` means pi will auto-retry after a transient
      // error; only the terminal agent_end (or process exit) ends the turn.
      if (evt.willRetry !== true) finish();
    } else if (kind === "auto_retry_start") {
      // A retry is starting after a transient failure — clear any captured
      // state so a later success is not masked by stale output.
      lastError = "";
      assistantText = "";
    } else if (kind === "auto_retry_end") {
      if (evt.success === false) {
        if (evt.finalError) lastError = String(evt.finalError);
        finish();
      }
    } else if (kind === "error") {
      // Defensive: a top-level error event (not normally emitted in
      // --mode json) terminates the turn.
      clearIdle();
      finalEmitted = true;
      fatal(evt.message || evt.errorMessage || "pi reported error");
    }
  });

  child.stderr.on("data", (chunk) => {
    logLine("pi_stderr", { chunk: chunk.toString("utf8") });
  });

  child.on("exit", (code, signal) => {
    clearIdle();
    logLine("pi_exit", { code, signal });
    if (!finalEmitted) {
      if (code === 0 || assistantText) {
        finish();
      } else {
        finalEmitted = true;
        send({ type: "error",
               message: (lastError ||
                 `pi exited with code=${code} signal=${signal || ""}`.trim()) });
      }
    }
    if (logFd !== null) { try { closeSync(logFd); } catch (_e) {} }
    process.exit(0);
  });
}

run().catch((e) => fatal(e && e.message ? e.message : String(e)));

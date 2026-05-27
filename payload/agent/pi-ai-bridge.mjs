#!/usr/bin/env node
// pi-ai-bridge.mjs — minimal stdin/stdout bridge from Ubuntu Zombie's
// Python chat service to the @earendil-works/pi-ai library.
//
// Phase 1 (UPGRADE-TO-PI-PLAN.md §4) replaces the bespoke OpenAI and
// Anthropic clients in payload/agent/providers.py with a thin adapter
// that shells out to this script. The Python surface (provider.chat)
// is preserved so server.py is unchanged.
//
// Wire format
// -----------
// stdin: a single JSON object
//   {
//     "provider": "openai" | "anthropic" | "gemini" | "xai"
//                 | "openrouter" | "mistral" | "groq",
//     "model":    "<provider model id>",
//     "messages": [{ "role": "system"|"user"|"assistant",
//                    "content": "..." }, ...]
//   }
//
// stdout: a single JSON object
//   { "ok": true,  "text": "<assistant reply>" }                (success)
//   { "ok": false, "error": "<message>", "code": "<short id>" } (failure)
//
// The bridge never reads provider keys directly — it relies on the
// environment variables already in scope (OPENAI_API_KEY,
// ANTHROPIC_API_KEY, GEMINI_API_KEY, XAI_API_KEY,
// OPENROUTER_API_KEY, MISTRAL_API_KEY, GROQ_API_KEY) which
// payload/agent/providers.py forwards from the secrets file.

import { readFileSync } from "node:fs";

// Map Ubuntu Zombie provider names (operator-visible) to the provider
// ids that @earendil-works/pi-ai uses internally. Keep this list in
// lockstep with providers.py's _PI_AI_PROVIDERS.
const PROVIDER_MAP = {
  openai: "openai",
  anthropic: "anthropic",
  gemini: "google",
  xai: "xai",
  openrouter: "openrouter",
  mistral: "mistral",
  groq: "groq",
};

// Map provider name to the env var that must be set. Mirrors
// providers.py so error messages on the Python side and here agree.
const KEY_ENV = {
  openai: "OPENAI_API_KEY",
  anthropic: "ANTHROPIC_API_KEY",
  gemini: "GEMINI_API_KEY",
  xai: "XAI_API_KEY",
  openrouter: "OPENROUTER_API_KEY",
  mistral: "MISTRAL_API_KEY",
  groq: "GROQ_API_KEY",
};

function emit(obj) {
  process.stdout.write(JSON.stringify(obj));
  process.stdout.write("\n");
}

function die(error, code = "bridge_error") {
  emit({ ok: false, error: String(error), code });
  process.exit(1);
}

async function readStdin() {
  // Allow the caller to pass the request as a file path argument
  // (used by unit tests) or, by default, read JSON from stdin.
  if (process.argv[2]) {
    return readFileSync(process.argv[2], "utf8");
  }
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

async function main() {
  let raw;
  try {
    raw = await readStdin();
  } catch (err) {
    die(`failed to read request from stdin: ${err.message}`, "stdin_error");
  }

  let req;
  try {
    req = JSON.parse(raw);
  } catch (err) {
    die(`request is not valid JSON: ${err.message}`, "bad_request");
  }

  const provider = String(req.provider || "").toLowerCase();
  const piProvider = PROVIDER_MAP[provider];
  if (!piProvider) {
    die(
      `unknown provider "${provider}"; supported: ${Object.keys(PROVIDER_MAP).join(", ")}`,
      "unknown_provider",
    );
  }

  const keyEnv = KEY_ENV[provider];
  if (keyEnv && !process.env[keyEnv]) {
    die(`${keyEnv} is not set`, "missing_key");
  }

  const model = String(req.model || "").trim();
  if (!model) {
    die(`model id is required for provider "${provider}"`, "missing_model");
  }

  const messages = Array.isArray(req.messages) ? req.messages : [];
  // pi-ai's Context separates the system prompt from the message list.
  const systemParts = [];
  const userMessages = [];
  for (const m of messages) {
    if (!m || typeof m !== "object") continue;
    const role = String(m.role || "");
    const content = m.content == null ? "" : String(m.content);
    if (role === "system") {
      systemParts.push(content);
    } else if (role === "user" || role === "assistant") {
      userMessages.push({ role, content });
    }
  }

  let pi;
  try {
    pi = await import("@earendil-works/pi-ai");
  } catch (err) {
    die(
      `failed to load @earendil-works/pi-ai: ${err.message}. ` +
        "Reinstall via scripts/install.sh.",
      "pi_ai_missing",
    );
  }

  let modelHandle;
  try {
    modelHandle = pi.getModel(piProvider, model);
  } catch (err) {
    die(
      `unknown model "${model}" for provider "${provider}": ${err.message}`,
      "unknown_model",
    );
  }

  const context = {
    systemPrompt: systemParts.join("\n\n") || undefined,
    messages: userMessages,
    tools: [],
  };

  let result;
  try {
    result = await pi.complete(modelHandle, context);
  } catch (err) {
    die(`provider call failed: ${err.message || err}`, "provider_error");
  }

  // pi-ai's complete() returns an updated Context. The assistant's
  // reply is the last message; concatenate text parts when the content
  // is an array (some providers return structured content).
  const last = result?.messages?.[result.messages.length - 1];
  emit({ ok: true, text: extractAssistantText(last) });
}

function extractAssistantText(message) {
  if (!message || message.role !== "assistant") return "";
  const content = message.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.map(textOfPart).join("");
}

function textOfPart(part) {
  if (typeof part === "string") return part;
  if (part && typeof part.text === "string") return part.text;
  return "";
}

main().catch((err) => die(err.stack || String(err), "uncaught"));

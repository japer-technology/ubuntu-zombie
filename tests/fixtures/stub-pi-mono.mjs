#!/usr/bin/env node
// tests/fixtures/stub-pi-mono.mjs
//
// Minimal pi-mono bridge stub used by tests/smoke.sh. Speaks the
// same line-delimited JSON protocol as payload/agent/pi-mono-bridge.mjs
// but does not require `pi` or `node`-native modules other than what
// ships with Node >=18.
//
// The stub script reads ZOMBIE_STUB_PLAN (a JSON array) and emits
// each step in order. Defaults to a single read-only fs.read call
// against /etc/os-release followed by a "final" message — enough to
// exercise the schema-validation + dispatch + observation path.

import { createInterface } from "node:readline";

function send(obj) { process.stdout.write(JSON.stringify(obj) + "\n"); }

const plan = JSON.parse(process.env.ZOMBIE_STUB_PLAN || JSON.stringify([
  { type: "tool_call", id: "1", name: "fs.read",
    args: { path: "/etc/os-release", max_bytes: 256 } },
  { type: "final", text: "stubbed pi-mono turn complete" },
]));

const rl = createInterface({ input: process.stdin });
let received = 0;

rl.on("line", (line) => {
  received += 1;
  if (received === 1) {
    // First line is always the 'start' frame. Replay the plan.
    let i = 0;
    function step() {
      if (i >= plan.length) return;
      const item = plan[i++];
      send(item);
      if (item.type === "final" || item.type === "error") {
        process.exit(0);
      }
    }
    step();
    rl.on("line", () => step());
  }
});

rl.on("close", () => process.exit(0));

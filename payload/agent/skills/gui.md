<!-- triggers: gui, screenshot, click, type, keyboard, mouse, desktop, x11, xdotool -->
# Skill: GUI control (Xorg desktop)

This skill is loaded when the operator asks for screenshots,
mouse/keyboard automation, or anything else that touches the X
desktop.

Operating rules:

- `gui.screenshot` is `read_only` and runs automatically. It captures
  the current desktop via the `gnome-screenshot` helper wired by the
  installer.
- `gui.click` and `gui.type` are `user_change` and require operator
  approval. Each call is one action; do not chain clicks "to save
  approvals" — that defeats the gate.
- Coordinates passed to `gui.click` are in screen pixels of the
  current `DISPLAY`. Take a fresh screenshot before reasoning about
  positions; window layouts can move between turns.
- Never type strings that look like secrets (tokens, passwords) via
  `gui.type`. The text is logged in clear in the audit log and the
  conversation history. If the operator asks you to fill a password
  field, refuse and explain.
- The desktop session belongs to the same Linux user the chat
  service runs as. Treat it as an interactive session the operator
  may also be using; minimise focus-stealing and do not close
  windows you did not open.

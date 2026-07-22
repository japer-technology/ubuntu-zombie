# Analysis notes

Working notes from repository-wide reviews. Unlike the user docs one
level up, these are **internal engineering records**: each file lists
concrete issues that were found, what was decided, and whether the fix
has landed. They are kept so a future review can re-check the same
ground without rediscovering it from scratch.

- [`improvements-1.md`](improvements-1.md) — first full-repository
  review and its periodic reanalysis: each originally raised issue,
  re-checked against the current tree.
- [`improvements-2.md`](improvements-2.md) — second review pass with
  the same structure.
- [`improvements-3.md`](improvements-3.md) — design analysis of a
  component-oriented install/uninstall CLI (verb + component targets,
  standalone Forgejo, component registry and manifest).
- [`install-enhancement-1.md`](install-enhancement-1.md) — focused
  analysis of installer UX and robustness enhancements.
- [`improvements-8.md`](improvements-8.md) — external adversarial
  review (2026-07-21): mediated-tool-path bypass (F1, critical), test
  coverage realism, auth fail-open, and a sequenced remediation plan.
- [`improvements-8-plan.md`](improvements-8-plan.md) — phased
  implementation plan addressing every improvements-8 finding
  (F1–F12), with work items, acceptance criteria, and sequencing.
- [`improvements-8-plan-phase-1-option-a.md`](improvements-8-plan-phase-1-option-a.md)
  — deep implementation analysis of Phase 1 Option A (`--mode rpc`
  mediation via a shipped pi extension), including the router
  on/off operator control, chat-UX truth in `/verbose`, a
  full-dump `/export`, and documentation-truthfulness sequencing.
- [`mediation-diagrams/`](mediation-diagrams/README.md) — vertical
  Mermaid diagrams comparing how the system works today (shipped
  unmediated bridge path) with the restored mediation designs from
  the improvements-8 plan.
- [`reactivation-timer.md`](reactivation-timer.md) — design analysis for
  a timer-backed agent re-activation primitive and queued chat
  continuations.

If you are looking for how to *use* or *understand* Ubuntu Zombie,
start at [`../README.md`](../README.md) (the documentation index)
instead.

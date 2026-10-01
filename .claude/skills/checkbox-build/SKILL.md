---
name: checkbox-build
description: Use for ANY roadmap work on this repo — starting, continuing, implementing, testing or ticking a week/checkbox from the Notion "05 — 15-Week Roadmap and Submission" page, or touching Notion at all. Enforces the Notion scope rule and the one-checkbox-at-a-time build cycle.
---

# Checkbox build process

## HARD RULE — Notion scope
- In Notion, read or write **only** the page "05 — 15-Week Roadmap and Submission"
  (id `3eb89157-367c-81c8-b7f6-f08dd8ff0fa5`). It holds both the roadmap and the
  submission checklist.
- Never open, search into, read or write any other Notion page, database or
  workspace — not even pages it @-mentions. Fetch this page by id; do not search.
- If Notion is unreachable, say so and stop ticking; do not fall back to guesses.

## Source of truth for the plan
- The plan is the Notion page above. Do **not** use the local
  `FLASHSALE_EXECUTION_CHECKLIST.md` or any other local plan markdown as the plan.
- The repo (code, `docs/`, `report/report.tex`) is the evidence, not the plan.

## The cycle — per checkbox, never one-shot
Take the earliest unticked checkbox (start at Week 1). For that one box only:

1. **Prototype / proof of concept** — smallest spike that proves the approach.
   Then **throw it away** (do not commit it).
2. **Design spec** — write what will change and how it will be verified, in the
   relevant `docs/` file. Each claim must map to code or an explicitly open task.
3. **Implement.**
4. **Write tests** — automated where possible (`tests/`), otherwise a scripted
   check with saved output.
5. **Debug** — loop 3→4→5 until everything is green.
6. **Checkpoint** — commit on the work branch with a message naming the checkbox.
7. **Alpha test** — run it yourself end to end on the real stack.
   **Beta test** — re-run from a clean state (fresh build/reset) as a newcomer would.
8. **Release** — push; update the report section the box asks for.

## Ticking rule
- Tick only when the work is verified 100% and matches the checkbox text **word
  for word** (every noun in the box has evidence). Partial = leave unticked and
  write what is missing next to it.
- After ticking, document: what changed, the commands run, and where the
  evidence lives (file paths / commit SHA). A milestone box (W01, M1…) closes only
  when all its child boxes are ticked with evidence.
- Report progress in the project thread after every checkbox.

## Decisions already made
- 2026-10-01 — Order states follow the teacher's **six-state** model:
  PendingStock, Confirmed, Rejected, Processing, Completed, ProcessingFailed.
  `Processing` is real (with history); `ProcessingFailed` is declared but no
  event reaches it (success-only Worker) and must be documented that way.

## Git conventions
- Branch names are plain (e.g. `week1-2`, `week3`); never `claude/...` or any
  AI/tool name. Commit messages name the checkbox, with no AI attribution.

## Gotchas
- `.gitignore` ignores `*.md` except `/README.md`, `/CLAUDE.md`, `docs/**` and
  this skill folder. Switching branches silently overwrites ignored local copies
  of tracked docs — back them up first.
- The groundwork plugin blocks file writes unless bypassed
  (`/groundwork-specflow:bypass <reason>`, 60 minutes).
- Branch names (`week11`) do not mean a week is accepted; only ticked boxes with
  evidence do.

## References
- https://github.com/shanraisshan/claude-code-best-practice — short CLAUDE.md,
  skills as folders with trigger-focused descriptions and a Gotchas section,
  Research → Plan → Execute → Review → Ship, vertical slices.
- https://claudelog.com/ — plan before acting, small testable increments,
  compile/validate immediately, sanity checks and checkpoints.

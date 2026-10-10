---
name: checkbox-build
description: Use for ANY roadmap work on this repo — starting, continuing, implementing, testing or ticking a week/checkbox from the Notion "05 — 15-Week Roadmap and Submission" page, checking the 03 Correctness worklist, or touching Notion at all. Enforces the Notion scope rule (the project hub tree only) and the one-checkbox-at-a-time build cycle.
---

# Checkbox build process

## HARD RULE — Notion scope (owner, updated 2026-10-10)
- In Notion, use **only** the hub "Flash-Sale Microservices — Project Plan and
  Progress Hub" (id `3eb89157-367c-81e9-9afb-cd791dfe2cea`), its seven
  numbered subpages, and the subpages inside those. Fetch them by id and never
  use Notion search.

  | Page | Id |
  |---|---|
  | 00 — Requirements and Acceptance | `3eb89157-367c-81bf-bbd3-e7e389647221` |
  | 01 — Architecture and Class Diagram | `3eb89157-367c-8164-9429-c15a2e9a4b4e` |
  | 02 — Current Progress and Grade | `3eb89157-367c-811a-acc7-f7b8dc79b587` |
  | 03 — Correctness and Reliability Worklist | `3eb89157-367c-8119-8877-fdc4478c3cea` |
  | 03A — Baseline, Order API and Lifecycle | `3ec89157-367c-8172-a871-fd409963d097` |
  | 03B — Inventory and Reliable Messaging | `3ec89157-367c-813a-abae-c386a91cbaf3` |
  | 03C — Worker, Trace and Observability | `3ec89157-367c-8165-ad71-ee5c6790221f` |
  | 03D — Deployment, Experiments and Submission | `3ec89157-367c-81fa-8b57-cbebb366fb11` |
  | 04 — Experiment Plan and Metrics | `3eb89157-367c-8174-835a-e41056930dd7` |
  | 05 — 15-Week Roadmap and Submission | `3eb89157-367c-81c8-b7f6-f08dd8ff0fa5` |
  | 06 — 9+ Grade Score Plan | `3eb89157-367c-8108-80d7-e7ca027f71e2` |

- **Do not touch anything else.** Never open, read or write any page,
  database or workspace that is not in that tree. This includes links that
  point outside it, such as the hub's "Structure reference" (the Flutter
  plan). Within the tree, use only what is listed in these pages.
- **How each page is used:**
  - 05 is the weekly plan; tick its boxes one at a time.
  - **03 and its 03A–03D reports are the correctness checklist.** During every
    code check, read the 03 items and the 03A/B/C/D scenario rows (for
    example B-09) that cover the box. The work must satisfy them too. Tick a
    03 or 03A–D box only when its own text is fully proven, with a note.
  - 00 is the requirements and acceptance register.
  - 01 holds the architecture.
  - 02 holds the evidence and grade.
  - 04 holds the experiment plan.
  - 06 holds the 9+ grade gates ("go here" for grading standards).
- If Notion is unreachable, say so and stop ticking; do not fall back to guesses.
- **Edit Notion minimally, on every page.** Never rewrite, reorder or restyle.
  Only flip `[ ]`/`[x]` and append a short evidence note after the box's own
  text, keeping the original wording intact. Never change a box's wording so
  it deviates from the teacher's brief (`docs/teacher-brief.md`).

## Study guide (owner's reference)
`.claude/skills/checkbox-build/study-guide.md` summarises the owner's "Flash
Sale Microservices Study Guide" (523V0012, 7 Oct 2026). Before each code
check, read the guide's chapter for that week's topic and hold the work to it.
For example, chapter 9 covers retries, the DLQ, compensation and the failure
matrix for Week 10. Its examples are teaching material, not claims about this
code.

## Source of truth for the plan
- The plan is the Notion 05 page above (with 03 as the correctness checklist). Do **not** use the local
  `FLASHSALE_EXECUTION_CHECKLIST.md` or any other local plan markdown as the plan.
- The repo (code, `docs/`, `report/report.tex`) is the evidence, not the plan.
- The teacher's brief is saved verbatim in `docs/teacher-brief.md`. It is the
  acceptance standard (what the result must satisfy), not the plan. Check each
  checkbox's result against it; flag conflicts with Notion to the owners.

## Roles (owner decision 2026-10-03)
- **DeepSeek Harness codes** (cycle steps 1–5) through its Web UI on
  http://127.0.0.1:3080, workspace D:\DACNTT. It never touches Notion or git
  unless told to.
- **Claude checks:** it writes DeepSeek's task, reviews the diff against
  AGENTS.md, re-runs tests, alpha, beta and negative controls itself, sends
  findings back until the work meets the standard, then commits, ticks Notion
  and reports. Claude may also give DeepSeek test-only tasks.

- **DS conduct (AGENTS.md Part 0b, owner 2026-10-04):** DS does only what
  the task message says and never states anything it has not checked. Claude
  verifies every DS claim. When DS fails or reports falsely, Claude
  investigates the real cause, sends a review file in `.agent-tasks/`, allows
  up to 3 rounds, then fixes the work itself and tells the owner what DS could
  not do.
- **Every DS false claim becomes a new rule (owner, 2026-10-04).** When DS
  states anything false (a fix that is not in the file, a result it did not
  get, an edit it denies), Claude immediately adds a numbered rule to
  AGENTS.md Part 0b "Rules from incidents" (I1, I2, …). The rule names the
  date, the box and what DS said versus the truth, and states the concrete
  check that prevents a repeat. Claude commits it, tells DS to re-read
  Part 0b, and lists the incident in the owner report.

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
- **Env files stay out of git, always** (user rule, 2026-10-03): `.gitignore`
  must list `.env`, `.env.*` and `*.env` (allowing only `.env.example`), even
  when no env file exists yet. Check it before every commit; never commit API
  keys, passwords or tokens.

## Gotchas
- `.gitignore` ignores `*.md` except `/README.md`, `/CLAUDE.md`, `/AGENTS.md`,
  `docs/**` and this skill folder. Switching branches silently overwrites
  ignored local copies of tracked docs — back them up first.
- The groundwork plugin blocks file writes unless bypassed
  (`/groundwork-specflow:bypass <reason>`, 60 minutes).
- Branch names (`week11`) do not mean a week is accepted; only ticked boxes with
  evidence do.

## Detailed rulebook
- `AGENTS.md` at the repo root spells out every rule and every step above in
  detail, for DeepSeek Harness and other agents. When the owner adds or
  changes a rule, update SKILL.md, CLAUDE.md and AGENTS.md together.

## References
- https://github.com/shanraisshan/claude-code-best-practice — short CLAUDE.md,
  skills as folders with trigger-focused descriptions and a Gotchas section,
  Research → Plan → Execute → Review → Ship, vertical slices.
- https://claudelog.com/ — plan before acting, small testable increments,
  compile/validate immediately, sanity checks and checkpoints.

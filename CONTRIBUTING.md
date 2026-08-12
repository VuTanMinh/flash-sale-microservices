# Branching Convention

Per `FLASHSALE_EXECUTION_CHECKLIST.md` Step 2.2: work on feature branches
(`feat/order-service`, `feat/outbox`, etc.) and merge to `main` via pull request,
even solo — PRs give a searchable log of "what changed and why" per week, which is
genuinely useful when writing the Discussion chapter (Week 14) and reconstructing
your own decision history.

**Current deviation (Week 2):** this repo's default working branch is `week1`
(not `main`), per an explicit instruction to build on top of that branch rather
than `feat/dev-environment` as the checklist originally suggested. Week 2's setup
work (folder structure, Docker Compose, ERD, this file) lands directly on `week1`.
Starting Week 3, switch to real feature branches off of whatever the then-current
base branch is (`feat/c0-c1-baseline`, etc.), per the convention below — don't let
"we deviated once" become "we never branch."

## Convention going forward

- One feature branch per week's major unit of work: `feat/<short-name>`.
- Commit locally as you go; **push and open the PR yourself** — nothing in this
  repo is pushed on your behalf. Every step that needs a push in
  `FLASHSALE_EXECUTION_CHECKLIST.md` gives you the exact command to run.
- Read your own diff in the GitHub PR UI before merging, even solo — it catches
  things your editor's familiarity blinds you to (accidental secrets, stray debug
  files, etc.).
- Don't commit directly to `main` from Week 3 onward.

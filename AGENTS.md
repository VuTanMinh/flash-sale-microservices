# AGENTS.md — How to work on DACNTT (Flash-Sale Microservices)

This file is for any coding agent working in this repository: DeepSeek Harness
(`dsh`), Claude Code, or another. It records every working rule the owner has
given so far, and the exact way each kind of task has been done. Read all of it
before your first action. When a rule here conflicts with your own habits,
this file wins. When it conflicts with the owner's latest chat message, the
message wins. Then propose an update to this file so the two agree again.

Project summary: a capstone project. .NET 10 / ABP 10.6 microservices (Order
Service, Inventory Service, Process Worker) with PostgreSQL 16, Redis,
RabbitMQ (RabbitMQ.Client 7.1.2) and Nginx, plus a LaTeX report at
`report/report.tex`. GitHub: `VuTanMinh/flash-sale-microservices`.
Work branch: `week1-2`.

---

## Part A. Hard rules (never break these)

### A1. Notion: one page only
- In Notion you may read or write **only** the page
  "05 — 15-Week Roadmap and Submission", id `3eb89157-367c-81c8-b7f6-f08dd8ff0fa5`.
  It holds the roadmap and the submission checklist.
- Never open, search, read or write any other Notion page, database or
  workspace. This includes pages that this page @-mentions (the execution
  reports, the evidence page, the acceptance page). Fetch the page by its id
  and never use Notion search.
- **Edit minimally.** Never rewrite, reorder, restyle or reword the page. The
  only allowed edits are:
  1. flip one box from `- [ ]` to `- [x]`;
  2. append, after the box's own unchanged text, a note that starts with
     `— Done <YYYY-MM-DD> (<commit SHAs>, week1-2).` followed by the evidence:
     what changed, what was found, the commands, the pass counts, and the
     evidence file paths.
- Never change a box's wording, and never make it deviate from the teacher's
  brief (`docs/teacher-brief.md`).
- Use the exact `old_str` of the line you are ticking. Writes can be queued:
  wait for the task to finish, then fetch the page again and confirm the
  line now reads `[x]` with your note.
- If Notion is unreachable or you have no Notion tool, do not tick anything.
  Tell the owner exactly which box is ready and give the note text to paste.

### A2. Where the plan lives
- The plan is the Notion page above. Do **not** use
  `FLASHSALE_EXECUTION_CHECKLIST.md` or any other local plan markdown as the
  plan.
- The repository (code, `docs/`, `report/report.tex`, `tests/evidence/`) is the
  evidence, not the plan.
- `docs/teacher-brief.md` is the teacher's note, saved verbatim. It is the
  acceptance standard: every result must satisfy it. If Notion and the brief
  disagree, say so to the owner. Do not resolve it silently.

### A3. Secrets
- `.gitignore` must always list `.env`, `.env.*` and `*.env` (allowing only
  `.env.example`), even when no env file exists. Check this before every
  commit.
- Never commit, print or paste API keys, passwords or tokens. When you must
  look inside `.env` or a credentials file, print only the key names
  (`sed 's/=.*/=<hidden>/'`) and mask anything that looks like a key.
- `D:\DACNTT\.env` holds `ANTHROPIC_*` settings and a token. It is ignored and
  must stay that way. `deepseek-mcp-server/` is local tooling and also
  ignored.
- Never put a token into a URL, form or command unless the owner supplied it
  for that exact purpose. Even then, remind them that a pasted token should be
  rotated.

### A4. Git
- Branch names are plain (`week1-2`, `week3`). Never name a branch `claude/…`,
  `deepseek/…` or after any AI or tool.
- Commit messages name the checkbox (for example
  `fix: … (Week 8 P0 checkbox)` or `test: Week 9 delivery evidence …`). Add no
  AI attribution or co-author lines.
- Push with `git push -u origin week1-2`. If the push fails on the network
  (for example "Could not resolve host"), retry up to 4 times, waiting 2, 4, 8
  and 16 seconds.
- `.gitignore` ignores `*.md` except `/README.md`, `/CLAUDE.md`, `/AGENTS.md`,
  `docs/**` and the skill folder. Evidence `.md` files under `tests/` need
  `git add -f`, and so do evidence `.log` files you want committed.
- Never commit throwaway prototypes, scratch scripts or build output.

### A5. Honesty
- Tick a box only when the work is 100% done and every noun in the box text
  has evidence. A partial result stays unticked, with a note saying what is
  missing.
- A claim in docs or the report must point at committed evidence (a log under
  `tests/evidence/` or `tests/*/results/`, a commit, or a test case). If a
  claim has no saved output, label it with the report macro
  `\unverified{TP-xx}{Week n}` or remove it.
- Never let a check pass by default. Every verifier must be able to fail;
  prove that with a negative control (Part C, step 7).
- **When something fails, tell the owner what failed and why, so they can
  fix it.** Examples: Docker not answering, a site needing login, a missing
  tool, or a push blocked. Never hide a failure, and never "fix" it by
  weakening a test.

---

## Part B. Current state (update this when it changes)

- Weeks 1–8 are fully ticked in Notion, and so are milestones W01–W08, M2 and
  M3.
- **M1 is still open.** Inventory Service and the Process Worker have not been
  re-assessed for "running under their own accounts".
- Week 9 box 1 is ticked: Inbox uniqueness, local transaction and a crash
  after commit before ack (TP-M01, `scripts/verify-delivery.ps1`).
- **Next box:** Week 9 box 2, "Test concurrent duplicates, duplicate business
  events with new MessageId, and late/out-of-order completion; preserve one
  stock deduction and one applied business result."
- **Known open gap (design decision, do not hide it):** if `OrderProcessed`
  reaches Order Service while the order is still `PendingStock`, the message
  is dead-lettered instead of retried. It is assigned to Weeks 9 and 11
  (`docs/design-decisions.md`).
- **Decisions already made:**
  - The order state model is the teacher's six states: PendingStock,
    Confirmed, Rejected, Processing, Completed, ProcessingFailed.
  - The code still has four states. Processing will be driven by an
    `OrderProcessingStarted` event in Week 11.
  - ProcessingFailed is declared but has no producer (success-only Worker).
    Document it that way.
  - Only a PostgreSQL unique violation (23505) counts as a duplicate. Every
    other database error is retried, then dead-lettered.

---

## Part C. The build cycle — one checkbox at a time, never all at once

Take the **earliest unticked box** on the Notion page and do only that box.
Do every step below, in order, and keep the owner informed.

### Step 0. Code check (always first)
1. Read the box text word by word. List each noun and what would prove it.
2. Read `docs/teacher-brief.md` for the part that applies.
3. Read the actual code, config, docs and report section involved. Do not
   trust earlier claims. Check them against the code.
4. Write down every defect or false claim you find, with `file:line`. Past
   checks found real defects every week, for example:
   - publishers using `mandatory:false`;
   - every DB error treated as a duplicate;
   - a validator that could never fail;
   - stale diagrams;
   - a crash test that crashed at the wrong moment.

### Step 1. Prototype, then throw it away
- Build the smallest spike that proves the approach. Write it in a scratch
  folder or a throwaway clone, never in the repo.
- Run it, note the result, then delete it. Never commit it.

### Step 2. Design spec
- Write in the relevant `docs/*.md` file (create one if needed) what will
  change and how it will be verified.
- Every claim must map to code or to an explicitly open task.
- Add or update the test case row in `docs/test-plan.md` with status
  `NOT RUN` and evidence `—`.

### Step 3. Implement
- Match the surrounding code: its naming, comment density and the project's
  raw RabbitMQ.Client style.
- Test-only hooks must be off by default, and must never appear in any
  `appsettings.json`. Example: `FaultInjection:CrashBeforeAck*`.
- Build all three services:
  `dotnet build src/FlashSale.<Service>/FlashSale.<Service>.csproj`, with 0
  errors and 0 warnings.

### Step 4. Tests
- Unit tests: `dotnet test tests/FlashSale.OrderService.Tests` (currently
  43/43).
- Scripted checks: `scripts/verify-<topic>.ps1`, following the pattern in
  Part E. They must print `PASS`/`FAIL` lines and exit non-zero on any
  failure.

### Step 5. Debug
- Loop through implement, test and debug until everything is green.
- When a check fails, find the real cause. Never edit the check just to make
  it pass.

### Step 6. Checkpoint
- Commit on `week1-2`, naming the box (Part A4).
- Push.

### Step 7. Alpha, then beta
**Alpha.** Run the verifier yourself on the real stack:
- Start from a fresh verification database:
  `powershell -File scripts/verify-environment.ps1 -Mode Fresh -Keep`. This
  recreates container `verify-env-pg` on port 55432.
- Then run, for example:
  `powershell -File scripts/verify-<topic>.ps1 -Container verify-env-pg -DbPort 55432`.

**Beta.** Repeat from a clean clone, the way a newcomer would:
1. `git clone -b week1-2 <repo> <scratch>\betaN`
2. `powershell -File scripts\create-openiddict-cert.ps1` (a fresh clone has
   no `openiddict.pfx`)
3. `verify-environment.ps1 -Mode Fresh -Keep`
4. Build all three services.
5. Run the verifier, capturing its full output to
   `tests\evidence\<UTC yyyyMMddTHHmmssZ>-<topic>.log`, with a header that
   names the clone's commit, "fresh database" and the stamp.

**Negative control.** Copy the beta clone, break exactly one thing (for
example: ack before processing, skip the Inbox check, or a required queue that
does not exist), rebuild that service and run the verifier again. It must
fail on the checks tied to that break. Save that output too, as
`<stamp>-<topic>-negative-<what>.log`.

### Step 8. Release
1. Copy the evidence logs into the repo and `git add -f` them.
2. In `docs/test-plan.md`, set the case to `PASS` with **one** evidence path.
   `scripts/verify-test-plan.ps1` rejects a PASS without committed evidence.
3. Update `report/report.tex` (Part D). Compile it and read the pages.
4. Run every document verifier that touches what you changed:
   - `verify-test-plan.ps1`
   - `verify-design-chapter.ps1`
   - `verify-design-alignment.ps1`
   - `verify-design-decisions.ps1`
   - the matching `verify-*-report.ps1` with its stamp parameters
5. Commit, then push.
6. Tick the Notion box with its note (Part A1), then read the page back.
7. Report to the owner (Part F).

### Milestones
A week's `W0n` box closes only when all of its boxes are ticked with
evidence. A group milestone (M1–M8) closes only when all of its weeks pass.
Append a short note; never tick a milestone early.

---

## Part D. Report (`report/report.tex`)

- Keep the report matching the docs and the evidence. When a box changes
  behaviour or proves something, rewrite the matching report section from the
  evidence. Remove stale claims instead of leaving them.
- Use `\unverified{TP-xx}{Week n}` for any claim without saved output.
- Write LaTeX in separate `.tex` files with a file-writing tool, then splice
  them in with a short Python script that uses `BS = chr(92)` for
  backslashes. Shell heredocs and Python string literals mangle `\u`, `\t`
  and `\n`.
- Compile with
  `latexmk -pdf -interaction=nonstopmode -halt-on-error report.tex`, run in
  `report/`.
- **Always read the result.** Render the changed pages with
  `pdftoppm -r 70 -f <p> -l <p+1> -png report.pdf <out>` (find page numbers
  in `report.toc`) and look at them.
- Fix any of these:
  - text running into the margin (rephrase, or add `\allowbreak` between
    `\texttt{}` pieces);
  - half-empty pages caused by `[H]` tables (use `[tbp]`);
  - unreadable figures;
  - leftover placeholders.
- Diagrams: Mermaid sources live in `report/figures/*.mmd` and must equal
  the blocks in `docs/sequence-diagrams.md`. Render them with:

  ```
  npx -y @mermaid-js/mermaid-cli@11 -q -p <puppeteer.json> -c report/figures/mermaid-sequence.json -i X.mmd -o X.png -s 2
  ```

  Here `puppeteer.json` contains `{"executablePath": "C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1234/chrome-win64/chrome.exe", "args": ["--no-sandbox"]}`.
  Use that Playwright Chromium, because Edge sometimes fails to launch.

---

## Part E. How verifier scripts are written (copy this pattern)

- Windows PowerShell 5.1, `$ErrorActionPreference = "Continue"`, with a
  header comment that gives the test case id, what it proves and the exact
  command.
- A `Check "name" (bool) "detail"` function prints `PASS  name` or
  `FAIL  name -- detail` and counts failures. At the end, print a summary
  line and `exit 1` if anything failed.
- Each script brings up its own **throwaway RabbitMQ and Redis containers**
  on unique ports, so scripts never collide:
  - The RabbitMQ user is loaded from a definitions file with a salted
    SHA-256 `password_hash`.
  - It also loads `loopback_users = none`.
- Start services with `dotnet run --no-build --no-launch-profile` from
  `src\<Project>`:
  - Pass settings through environment variables, using the own-account
    connection strings `order_service_user` / `inventory_service_user`.
  - Set `Reconciliation__StuckTimeoutSeconds=3600` so reconciliation stays
    out of the way.
  - Give each start its own log file. Read logs with a shared-read
    `FileStream`, because the running service holds them open.
- Talk to PostgreSQL by piping SQL to
  `docker exec -i <container> psql -U flashsale -d flashsale -At -v ON_ERROR_STOP=1 -f -`.
  Never pass SQL with embedded quotes as a command-line argument.
- Compare only orderings that cause and effect guarantee. A publisher stamps
  `PublishedAt` after the confirm returns, so the consumer can commit first.
- Clean up in `finally`:
  - restore any revoked grants;
  - stop the service processes by `<Project>.exe` name;
  - remove the throwaway containers.
- Statuses: only PASS (and NOT APPLICABLE where documented) count as success.
  INCONCLUSIVE and SETUP ERROR exit non-zero.

### PowerShell 5.1 pitfalls (each one has bitten this project)
- Native stderr under `-ErrorAction Stop` throws. Use `Continue` and check
  exit codes yourself.
- Embedded double quotes are stripped from native arguments. Pipe SQL through
  stdin instead.
- A one-element array returned from a function unrolls to a scalar:
  `'2'[0]` is a char, and a `PSCustomObject` has no `.Count`. Wrap results in
  `@()` and parse with `[int]"$($v[0])"`.
- `$args`, `$force` and similar names collide with automatic variables. Do
  not use them as your own names.
- `"$p:"` inside a string is parsed as a drive reference. Write `"${p}:"`.
- Files that contain non-ASCII (for example em-dashes) need UTF-8 **with
  BOM**, or 5.1 misreads them.
- Do not pipe `start-order-service.ps1` output; the service inherits the pipe
  and hangs.
- `Set-Content` defaults to the ANSI codepage. Pass `-Encoding UTF8` or
  `ASCII` explicitly.

### Bash on this machine (Git Bash)
- An unquoted heredoc expands `$var`. Use `<<'EOF'`, or write the file with a
  file tool.
- `sleep` chains are slow. Poll with a loop and a timeout instead.

---

## Part F. Talking to the owner

- After **every** checkbox, report in the thread. Show every step explicitly
  (code check, prototype, design, implementation, tests, debug, checkpoint,
  alpha, beta, release), with the pass counts, the commits, the evidence
  paths, and what was found and fixed.
- Lead with what you need from the owner, if anything. Keep the language
  plain. Name failures and their cause.
- Ask before starting the next week. Within a week, continue box by box when
  the owner has said "proceed with week N".
- Before you start any task, re-read Part A.

---

## Part G. Environment facts

- Windows 11; repo at `D:\DACNTT`.
- SDK 10.0.300, pinned by `global.json`.
- Infra: `docker compose -f infra/docker-compose.yml up -d`.
- If Docker stops answering (`docker info` fails), start Docker Desktop, wait
  with a polling loop, and check again. If it still fails, tell the owner.
- Fresh verification database: container `verify-env-pg` on port 55432, from
  `verify-environment.ps1 -Mode Fresh -Keep`.
- Service ports already used by verifiers:
  - Order 5117–5126
  - throwaway RabbitMQ AMQP 5685–5688 / management 15685–15688
  - throwaway Redis 6395–6397

  Pick new ports for a new script.
- Redis keys: `inventory:{p}`, `processed:{p}`, `sale:open:{p}`. Use
  `scripts/warm-up.ps1 -Container <redis> -Products @{ p = n } [-Force]` to
  open a sale.
- JMeter is at `D:\tools\apache-jmeter-5.6.3`. LaTeX is MiKTeX `latexmk`.
- Inbox tables are `order_service.processed_messages` and
  `inventory_service.processed_messages`, with columns `Id`, `MessageId`
  (unique), `MessageType` and `ProcessedAt`.
- Outbox payloads are `jsonb` with PascalCase fields (`OrderId`, `MessageId`,
  `CorrelationId`).

## Part H. Useful references
- https://github.com/shanraisshan/claude-code-best-practice
- https://claudelog.com/
- `CLAUDE.md` (short) and `.claude/skills/checkbox-build/SKILL.md` (the same
  rules, for Claude Code).

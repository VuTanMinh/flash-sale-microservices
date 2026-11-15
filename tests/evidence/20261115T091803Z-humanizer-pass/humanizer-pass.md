# Humanizer pass on report/report.tex, 15 November 2026

Pre-flight: doc type = formal academic/technical course report; language = English; non-prose skipped =
LaTeX commands and preamble, comments, tables, figures and captions, Verbatim/code, maths, bibliography;
mode = humanize, mixed pass (Tier 1 full, Tier 2 clear hits, Tier 3 only if stacked, Tier 4 left alone);
fingerprint = not found (`~/.claude/voice-fingerprint.json` absent), overrides = none, voice sample = the
report's own wording; personality section not applied (no first person, opinions or casual tone in a
graded report); AI-iness density = 0 Tier 1 tells per 100 words.

## Scan

A pattern scan over the prose (about 40,000 words) found no Tier 1 tell at all: no "pivotal",
"crucial", "testament", "landscape", "robust", "seamless", "powerful", "comprehensive", "delve",
"underscore", "highlight", "showcase", "intricate", "foster", "leverage", "additionally", "notably",
"furthermore", "moreover", and no upbeat closers. Tier 2 found no "serves as", no tacked-on
"..., ensuring/highlighting/allowing/making" clauses, no filler ("in order to", "it is important to
note"), no authority tropes and no signposting beyond plain chapter openings that state their content.
The only clear Tier 2 hits were three "not just X" negative parallelisms (rule 9).

## Edits (3, all rule 9, chapter 8 Implementation)

| Section | Before | After |
|---|---|---|
| 8.2 Order Service (page 46) | This claim is verified directly, not just argued from the pattern's description, in `OutboxAtomicityTests.cs` | This claim is verified directly in `OutboxAtomicityTests.cs` |
| 8.2 Order Service (page 46) | --- the whole transaction rolled back, not just the failing half. | --- the whole transaction rolled back. |
| 8.6 Failure Handling (page 63) | The validation fixed a real bug, not just a gap. | The validation also fixed a real bug. |

Meaning, numbers, test ids, paths and claims are unchanged. Only three edits were justified, so the
log shows three examples, not ten.

## Considered and left as they are

- "run-to-run variation, not only averages" (Requirements): mirrors the teacher brief's wording.
- "So the check reads what the Worker did, not only where the messages ended up." (Appendix B): a real
  contrast that explains the check, not a rhetorical flourish.
- "The key is the client IP, which acts as one global bucket because JMeter runs from one machine."
  (8.8): "acts as" carries the meaning (it is one bucket only in practice); "is" would overstate it.
- Chapter and section openings such as "This chapter answers the four questions ..." state their
  content directly; they are not signposting filler.
- Bold inline headers in lists (rule 16, Tier 3) and em dashes (rule 14, Tier 4): left alone by the pass
  rules; they are the report's consistent house style.

## Structural issues flagged (not changed)

- Failure-mode table row F16 stays "Designed": TP-O03 recreates the crash state rather than injecting
  the crash, so a clause crediting TP-O03 under the table is optional and needs the owner's OK.
- Still open with the owner: an abstract, and lists of figures and tables. The AI-tools paragraph is
  absent and, by the owner's decision of 15 November 2026, stays out.

## Checks

Build: latexmk exit 0, 0 undefined references, largest overfull line 4.7 pt, 144 pages (unchanged),
main text 7-110 (unchanged). Report verifiers with the stamps in their headers: all PASS (summary.txt
in this folder): design-chapter 44, test-plan 287, freeze 106, observability-report 22,
design-alignment 53, design-decisions 28, requirements-trace 40, baseline-report 19, order-report 23,
publication-report 25, inventory-report 29, delivery-report 38, failure-report 103.

ran /humanizer on report/report.tex

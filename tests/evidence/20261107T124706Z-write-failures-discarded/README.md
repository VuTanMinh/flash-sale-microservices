# Discarded runs of verify-write-failures.ps1 (7 November 2026)

Both runs stopped on faults in the verifier, not in the services. They are kept so the record is complete.

- `20261107T124240Z-write-failures.log`: case A passed 9/9; case B stopped at an unexpected error because the
  script named a helper `History`, which PowerShell resolves to its built-in `history` alias (Get-History).
  The helper was renamed `HistRows`.
- `20261107T124401Z-write-failures.log`: 39 of 40 checks passed. B.4 failed only because its log count also
  matched the final "after 4 attempts; routing to DLQ" error line besides the 3 retry warnings (4 lines = 4
  attempts, the behaviour required). The check now counts the 3 warnings and the final error separately.

The passing run is `../20261107T124706Z-write-failures.log` (40/40, exit code 0).

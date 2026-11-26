# Report checks after the evidence paths were removed

The report now describes its evidence in words instead of repository paths.
The six report checks (baseline, order, inventory, delivery, publication,
failure) were changed so that each still requires the test result and its
test-case ID, and fails if any evidence path or timestamped file code is left
in its section.

- new-report/: the six checks on the new report, all PASS.
- old-report-negative/: the same checks on the previous report (b265ade,
  54 evidence paths). Each fails on exactly its changed lines (10 FAIL).

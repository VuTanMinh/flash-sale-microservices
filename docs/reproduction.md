# Reproducing the results on a fresh machine

This guide starts from a clean Windows 11 machine. Sections 1 to 5 end with the
same verifier and unit-test results that the reports cite. Section 7 rebuilds
every Week 14 Results table and figure from the saved raw data. Section 8 runs
a validated experiment on a local copy of the EC2 stack. All of that is local:
no cloud account is needed. The EC2 parts (sections 6 and 9) are optional and
only the repository owner can run them, because they create AWS resources.

## 1. Prerequisites

| Tool | Version used | Why |
|---|---|---|
| Windows PowerShell | 5.1 (built in) | every verifier is a `.ps1` script written for 5.1 |
| Docker Desktop | 4.x, Linux containers | PostgreSQL, Redis, RabbitMQ, Nginx and the throwaway verifier containers |
| .NET SDK | 10.0.300 or a later 10.0.3xx patch (`global.json`) | the three services and the unit tests |
| Git | any recent | clone |
| Apache JMeter + Java | 5.6.3 on Java 17+ (plans use no Groovy/JSR223) | load plans under `tests/jmeter/` (TP-L04, the smoke tests and section 8). Unpack it to `D:\tools\apache-jmeter-5.6.3`: `verify-ec2-stack.ps1` and the default of `run-matrix.ps1 -JMeterExe` expect that path |
| Python 3 + matplotlib | 3.14 and matplotlib 3.10 used here | the Results tables and figures (section 7) |
| TeX Live / MiKTeX | `latexmk` with `pdflatex` | only to rebuild the PDFs |

If Windows refuses to run the scripts ("running scripts is disabled"), allow
them for the current PowerShell window only:
`Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned`.

Free ports needed while verifiers run: 5432, 5672, 6379, 8080, 9090, 15672,
55432, and 5100–5199. Each verifier header lists the exact ports it uses.

## 2. Clone and build

```powershell
git clone -b main-test-bug-fix https://github.com/VuTanMinh/flash-sale-microservices
cd flash-sale-microservices
dotnet build src/FlashSale.OrderService.slnx --no-incremental
```

The build must end with `0 Error(s)`.

## 3. Unit tests

```powershell
dotnet test tests/FlashSale.OrderService.Tests
```

`OrderStateRacePostgresTests` needs a PostgreSQL connection and is skipped
(not passed) without one. To run it, start the verifier database from step 4,
then:

```powershell
$env:FLASHSALE_TEST_PG = "Host=localhost;Port=55432;Username=flashsale;Password=flashsale_dev;Database=flashsale"
dotnet test tests/FlashSale.OrderService.Tests
```

It creates and drops its own database (`flashsale_race_<random>`); it never
writes to the `flashsale` database.

## 4. The verifier database

Almost every runtime verifier needs a throwaway PostgreSQL on port 55432:

```powershell
powershell -File .\scripts\verify-environment.ps1 -Mode Fresh -Keep
```

It creates the container `verify-env-pg`, applies `infra/initdb`, runs both
services' migrations under their own accounts, and checks account isolation
and the ERD. Use a fresh one for a clean reproduction: verifiers share it, and
rows from an earlier interrupted run can disturb a later one.

## 5. Verifiers

Run them one at a time (they share the database container and some ports).
Each prints `PASS`/`FAIL` lines and exits 1 on any failure. The usual call is:

```powershell
powershell -File .\scripts\verify-<name>.ps1 -Container verify-env-pg -DbPort 55432
```

Verifiers start the services with `dotnet run --no-build`, so build first
(step 2) and again after any code change.

Which verifier proves which requirement, and the saved log of its latest run,
is listed in [evidence-index.md](evidence-index.md). The full test catalogue
with inputs and expected results is [test-plan.md](test-plan.md).

To save evidence the way the repository does, redirect the whole output:

```powershell
$ts = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
powershell -File .\scripts\verify-delivery.ps1 -Container verify-env-pg -DbPort 55432 *>&1 | Out-File "tests\evidence\$ts-delivery.log" -Encoding utf8
```

The local overload test (TP-L04, `verify-load-shedding.ps1` case H) also needs
JMeter on the PATH or `-JMeterHome`; see the script header.

## 6. EC2 (owner only, creates AWS resources)

The runbook is [deployment.md](deployment.md). It needs the owner's AWS
account and authorization: `terraform apply` creates two EC2 instances and
costs money until `terraform destroy`. Nothing in steps 1–5 depends on it.
Before destroying, copy every raw file back (deployment.md, "Evidence to
save"); the Week 12 EC2 overload run kept only its console summary.

## 7. Rebuild the Week 14 Results from the saved data

The 66 official runs are saved, unedited, in
`tests/evidence/20261105T104832Z-official/`: per round a backend bundle (each
run's validator log, extraction summary, stage intervals and collector
samples) and a JMeter bundle (each run's raw JTL), with every manifest in
`manifests.tgz`. `summary.log` there is the mechanical check of all 66 runs.

```powershell
python report/figures/analyze_official.py
git status report/figures/official
```

The script unpacks the bundles into a temporary folder and writes
`report/figures/official/`: `runs.csv` (one row per run), `cells.csv` (median
and range per cell), the `tab-*.tex` tables the report includes and the
`fig-*.png/pdf` figures. On an unchanged checkout `git status` should list no
modified file: the numbers and figures are rebuilt from the raw data, not
typed in.

Then rebuild the report:

```powershell
cd report
latexmk -pdf -interaction=nonstopmode -halt-on-error report.tex
```

The older figures come from their own scripts: `plot_week12.py` reads one run
folder holding `raw.jtl` and `samples.csv` (the archived Week 12 overload run is
`tests/evidence/20261023T144923Z-overload-raw.jtl` and `-samples.csv`), and
`latency_split.py` draws the latency split. The progress report is
`report/progress/progress-report.tex`.

## 8. A validated experiment run on a local copy of the EC2 stack

This runs the same matrix runner as the official runs, on the EC2 Compose file
started under a separate project on this machine. It needs Docker Desktop and
JMeter (section 1). Build first (section 2).

```powershell
powershell -ExecutionPolicy Bypass -Command "& .\scripts\verify-ec2-stack.ps1 -Cases A,G"
```

Use `-Command` as shown: with `powershell -File` the list `A,G` arrives as one
string and the script rejects it.

Case A builds the three service images and starts the stack; case G runs
`scripts/run-matrix.ps1` with a C3 then a C2 run (5/s for 10 s), each with a
reset, seed and warm-up, the collector, an open-loop JMeter load, the drain,
the validator and a database dump. It ends with `All checks passed`. The runs
are in `%TEMP%\ec2v-matrix\`: each folder holds `manifest.json` (status
`PASS`), `raw.jtl`, `samples.csv` and `validator.log` (`RESULT: all checks
hold`, with checks 0b and 7). The stack is removed again at the end.

Then regenerate those runs' own table and figures with the same definitions as
the official Results:

```powershell
python report/figures/analyze_official.py --runs "$env:TEMP\ec2v-matrix" reproduction
```

It writes `reproduction/runs.csv`, `reproduction/tab-runs.tex` and one
`fig-<run-id>.png` per run (responses per second, then the Outbox and queue
backlog), prints one line per run and exits 0 only if every run has status
`PASS` and `all checks hold`.

## 9. The official matrix on EC2 (owner only)

The plan is [week14-official-runs.md](week14-official-runs.md) and the owner's
AWS steps are [week14-manual-steps.md](week14-manual-steps.md). The values
used are frozen in [week14-freeze.md](week14-freeze.md); check them first:

```powershell
powershell -File .\scripts\verify-freeze.ps1
```

It must end with `All 100 checks passed`.

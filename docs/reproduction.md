# Reproducing the Week 1–12 results on a fresh machine

This guide starts from a clean Windows 11 machine and ends with the same
verifier and unit-test results that the progress report cites. Every step is
local: no cloud account is needed. The EC2 part (section 6) is optional and
only the repository owner can run it, because it creates AWS resources.

## 1. Prerequisites

| Tool | Version used | Why |
|---|---|---|
| Windows PowerShell | 5.1 (built in) | every verifier is a `.ps1` script written for 5.1 |
| Docker Desktop | 4.x, Linux containers | PostgreSQL, Redis, RabbitMQ, Nginx and the throwaway verifier containers |
| .NET SDK | 10.0.300 or a later 10.0.3xx patch (`global.json`) | the three services and the unit tests |
| Git | any recent | clone |
| Apache JMeter + Java | 5.6.3 on Java 17+ (plans use no Groovy/JSR223) | load plans under `tests/jmeter/` (only for TP-L04 and the smoke tests) |
| Python 3 + matplotlib | 3.14 used here | only to rebuild the report figures |
| TeX Live / MiKTeX | `pdflatex` | only to rebuild the PDFs |

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

## 7. Rebuild the report (optional)

```powershell
# plot_week12.py reads one run folder holding raw.jtl and samples.csv; the
# archived overload run is in tests/evidence:
New-Item -ItemType Directory -Force run | Out-Null
Copy-Item tests/evidence/20261023T144923Z-overload-raw.jtl run/raw.jtl
Copy-Item tests/evidence/20261023T144923Z-overload-samples.csv run/samples.csv
python report/figures/plot_week12.py run
python report/figures/latency_split.py
cd report;          pdflatex report.tex;            pdflatex report.tex
cd progress;        pdflatex progress-report.tex;   pdflatex progress-report.tex
```

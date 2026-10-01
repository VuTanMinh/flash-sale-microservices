# Experiment Protocol

## Workload profiles

Run ramp-up, steady load, spike, sustained overload, and recovery profiles. Include both one hot product and multiple products with a skewed request distribution. For each profile, test request volumes below, near, and above initial inventory. Keep request payload and configuration identical when comparing implementations.

## Run setup

1. Record the code revision and C0–C4 configuration.
2. Record EC2 instance type/resources, service and dependency versions/configuration, Inventory Service replica count, products, initial stock, payload size, JMeter virtual users, target/observed request rate, and duration.
3. Reset and seed PostgreSQL and Redis, then run the documented warm-up. Confirm the starting stock before sending measured traffic.
4. Run JMeter on a separate machine from the EC2 host.
5. Save the JMeter plan, raw result file, application logs/metrics, broker queue/DLQ evidence, and correctness-validation output under the same run identifier.
6. Validate correctness and accepted-order liveness after every run. Do not include invalid runs in performance summaries; preserve them with the failure reason.
7. Repeat every configuration at least three times (target five) under equivalent conditions.

## Measurements

- HTTP acceptance latency and end-to-end terminal-state latency: p50, p95, p99.
- Incoming, accepted, rejected, and completed throughput; report API throughput separately from business-completion throughput.
- Stock decisions, internal errors, queue depth, oldest message age, retry/duplicate count, DLQ count, pending orders, backlog-drain time, and recovery time.
- CPU, memory, database connections, Redis latency, and RabbitMQ publish/delivery/acknowledgement rate.

## C0/C1 smoke run

Start the Compose services (or a throwaway database with `scripts/verify-environment.ps1 -Mode Fresh -Keep`). On an existing PostgreSQL volume, apply the role SQL once as described in `docs/infrastructure.md`. Start Order Service on port 5100:

    dotnet run --project src/FlashSale.OrderService --no-launch-profile --urls http://localhost:5100

Then run the checked smoke test. Add `-Container verify-env-pg` for the throwaway database; leave it out for the Compose database:

    powershell -ExecutionPolicy Bypass -File .\scriptsun-jmeter-smoke.ps1 -JMeter <path>in\jmeter.bat

The script resets and seeds the database, then runs `tests/jmeter/smoke-test.jmx` (10 threads, one `POST /api/c1/orders` each for `flash-product-1`). Each sample has two assertions: HTTP status 200, and a body that is a `Confirmed` decision for that product with a `remainingStock` value. The script saves the JTL and a summary as `tests/jmeter/results/<UTC stamp>-c1-smoke.*`. It then checks that the JTL holds 10 samples, all on `/api/c1/orders`, all 200, and all passing the assertions. It also checks the database: exactly 10 Confirmed C1 rows and stock 1000 → 990. Each run gets a new timestamped file, so earlier evidence is never overwritten. The target can be changed with `-Jhost`, `-Jport` and `-Jproduct`. Running with `-Product no-such-product` must fail, which proves the assertions bite.

## Comparison rules

- C0 demonstrates the race and is not a valid correctness baseline.
- C1 is the synchronous PostgreSQL correctness/performance baseline.
- C2 is the asynchronous event-driven design; C3 adds overload protection; C4 compares 1/2/4 consumer replicas on the same host.
- Keep hardware and workload fixed within each comparison. Report the median and run-to-run variation alongside latency percentiles; do not generalize beyond tested hardware, workload, or failure model.

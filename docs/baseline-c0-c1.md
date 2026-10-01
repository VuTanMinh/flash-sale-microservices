# C0 and C1 baseline captures (Week 3)

**Purpose:** prove the race that C0 demonstrates, and prove that C1 (PostgreSQL conditional atomic update) never oversells under concurrent demand below, equal to and above stock. These are correctness captures, not performance measurements. Performance runs follow `docs/experiment-protocol.md` and use JMeter on a separate machine.

## Configurations under test

| Config | Code | Mechanism |
|---|---|---|
| C0 | `src/FlashSale.OrderService/Experiments/C0Naive/C0NaiveDemo.cs` (`dotnet run -- --run-c0-demo`, no HTTP route) | Read stock, wait 50 ms, then an unconditional `UPDATE stock = stock - 1`. Every attempt starts behind one shared gate. |
| C1 | `POST /api/c1/orders` (`BaselineOrdersController`) | One `UPDATE ... SET stock = stock - 1 WHERE product_id = @p AND stock >= 1 RETURNING stock`, plus the `baseline_orders` log row, in one transaction. |

## Scenarios and pass rules

`scripts/run-baseline.ps1` runs all of them against a running Order Service and the database it uses.

| Scenario | Product / initial stock | Concurrent requests | Pass rule |
|---|---|---|---|
| C0 race | `c0-demo-product` / 1 | 5 | **Race captured:** more than 1 `Confirmed`, and final stock = 1 − Confirmed < 0. |
| C1 below | `c1-demo-product` / 100 | 50 | Every request returns HTTP 200; Confirmed = 50, Rejected = 0, final stock = 50. |
| C1 equal | `c1-demo-product` / 100 | 100 | Every request returns HTTP 200; Confirmed = 100, Rejected = 0, final stock = 0. |
| C1 above | `c1-demo-product` / 100 | 150 | Every request returns HTTP 200; Confirmed = 100, Rejected = 50, final stock = 0. |

All three C1 rules also require that stock never goes negative, Confirmed ≤ initial stock, and `baseline_orders` holds exactly one row per request. Every C1 scenario runs **3 times**. All requests in a scenario are started together, before any response is read.

## Evidence

Each run writes `tests/baseline/results/<UTC timestamp>-<scenario>-run<N>.json` with the commit, scenario, counts, HTTP status counts and verdict. The C0 console output is saved beside it as `...-c0-race.log`. A summary `...-summary.md` lists all verdicts. The script exits non-zero if any C1 rule fails, or if C0 does not show the race.

## Connection-pool finding (2026-10-01)

The first prototype ran with default settings. C1 never oversold, but 3–31 out of every 150–300 concurrent requests returned **HTTP 500** with `53300: sorry, too many clients already`. Npgsql's default pool (100 connections per service) is larger than what PostgreSQL's default `max_connections = 100` leaves for normal roles (97), and both services share that one server. The fix caps the pools so their sum stays under the server limit:

| Service | `Maximum Pool Size` |
|---|---|
| Order Service | 60 |
| Inventory Service | 30 |

That leaves headroom for the admin account and scripts. These pool sizes are part of the experiment configuration and must be recorded with every run.

# Local Infrastructure and AWS Target

## Docker Compose services

Run `docker compose -f infra/docker-compose.yml up -d` from the repository root. Compose starts dependencies and monitoring; the .NET services run separately on the host in the current branch.

| Service | Image in current Compose file | Host port(s) | Owner / purpose |
|---|---|---|---|
| PostgreSQL | `postgres:16` | `5432` | One local instance; service-owned schemas and distinct app roles |
| Redis Stack | `redis/redis-stack:latest` | `6379`, `8001` | Inventory keys; `8001` is RedisInsight |
| RabbitMQ | `rabbitmq:3-management` | `5672`, `15672` | Event broker; `15672` is the management UI |
| Nginx | `nginx:latest` | `8080` → container `80` | Current config is a placeholder; rate limiting/routing must not be claimed until Week 12 is verified |
| Prometheus | `prom/prometheus:latest` | `9090` | Scrapes the .NET services on the host |
| Grafana | `grafana/grafana:latest` | `3000` | Local metrics dashboards |

`latest` tags are mutable. Pin image versions and record the resolved image digests before official experiments.

## .NET toolchain and build

- **SDK:** pinned by `global.json` to `10.0.300` with `rollForward: latestPatch`, so any `10.0.3xx` patch at or above `10.0.300` is used and anything else fails fast. All projects target `net10.0`.
- **Framework:** ABP `10.6.0`; LeptonX Lite theme `5.4.0` (previously a floating `5.4.0-preview*`, now pinned so a clean build resolves the same package everywhere); `RabbitMQ.Client` `7.1.2`.
- **Clean build:** `dotnet build src/FlashSale.OrderService.slnx --no-incremental` builds all five projects (three services, event contracts, tests).
- **Migrations:** each service migrates with its own account (`--migrate-database`, connection string from `ConnectionStrings__Default`). Order Service writes `order_service` and ABP's `public` tables; Inventory Service writes only `inventory_service`.

`scripts/verify-environment.ps1 -Mode Fresh` checks all of this on a brand-new database: the SDK against `global.json`, the clean build, both migrations, account isolation and the ERD.

## PostgreSQL ownership

- `flashsale` is the local bootstrap/admin account only.
- `order_service_user` owns `order_service` and receives the `public` schema access required by Order Service's ABP tables.
- `inventory_service_user` owns `inventory_service` and has no access to `order_service`.
- The role and schema SQL is mounted under `infra/initdb/` and is applied automatically only when PostgreSQL initializes a fresh `pgdata` volume. On an existing volume, apply it once with:

  ```powershell
  Get-Content -Raw .\infra\initdb\01-create-service-roles.sql | docker compose -f .\infra\docker-compose.yml exec -T postgres psql -v ON_ERROR_STOP=1 -U flashsale -d flashsale
  ```

On an existing dedicated project database, this script also transfers existing public tables and sequences to the Order Service account and service-schema objects to their respective service accounts, so later migrations can alter them. It also moves Inventory Service's three migration-history rows out of the formerly shared `public."__EFMigrationsHistory"` into `inventory_service."__EFMigrationsHistory"`. Inventory now connects with `Search Path=inventory_service`, and without that move it would re-run its migrations and fail with `relation "outbox_events" already exists`. The script is safe to run more than once.

After applying it to an existing database, run both services' migrations once with their own accounts (`dotnet run --project FlashSale.OrderService --migrate-database`, then the same for `FlashSale.InventoryService`, from `src/`). Each should report that it completed with nothing to apply.

`scripts/schema/baseline-schema.sql` (run by `reset-and-seed.ps1`) hands the C0/C1 tables to `order_service_user`, so both paths end with the same owners.

### Verifying both paths

```powershell
# Fresh: new throwaway Postgres + initdb, build, both migrations, baseline schema, checks
powershell -ExecutionPolicy Bypass -File .\scripts\verify-environment.ps1 -Mode Fresh
# Existing: copy of the running local database, role script applied twice, migrations, checks
powershell -ExecutionPolicy Bypass -File .\scripts\verify-environment.ps1 -Mode Existing
```

Both modes run on a temporary container on port 55432 and never modify the running `infra-postgres-1` database. They finish with `scripts/verify-erd.ps1` and the account-isolation checks.

The committed credentials are local development values. Override service connection strings and bootstrap credentials for any non-local deployment.

## AWS deployment boundary

The teacher brief constrains backend services to one AWS EC2 host and JMeter to a separate machine. C4 replicas are processes or containers on that same host. Do not expose PostgreSQL, Redis, RabbitMQ management, Prometheus, or Grafana publicly for the experiment; make the API available only to the load-test source that needs it. Terraform and an EC2 deployment runbook are still required before the final submission; no AWS resources have been created by this project change.

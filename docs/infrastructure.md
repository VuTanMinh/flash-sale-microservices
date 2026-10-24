# Local Infrastructure and AWS Target

## Docker Compose services

Run `docker compose -f infra/docker-compose.yml up -d` from the repository root. Compose starts dependencies and monitoring; the .NET services run separately on the host in the current branch.

| Service | Image in current Compose file | Host port(s) | Owner / purpose |
|---|---|---|---|
| PostgreSQL | `postgres:16.14` | `5432` | One local instance; service-owned schemas and distinct app roles |
| Redis Stack | `redis/redis-stack:7.4.0-v8` | `6379`, `8001` | Inventory keys; `8001` is RedisInsight |
| RabbitMQ | `rabbitmq:3.13.7-management` | `5672`, `15672` | Event broker; `15672` is the management UI |
| Nginx | `nginx:1.31.3` | `8080` → container `80` | Reverse proxy to Order Service with the C3 rate limit on `POST /api/orders` (`docs/load-shedding.md`, TP-L01) |
| Prometheus | `prom/prometheus:v3.14.0` | `9090` | Scrapes the .NET services on the host |
| Grafana | `grafana/grafana:13.2.2` | `3000` | Local metrics dashboards |

Images are now pinned to full version tags (no `latest`, no bare major). Record the resolved image digests at the Week 13 freeze.

## .NET toolchain and build

- **SDK:** pinned by `global.json` to `10.0.300` with `rollForward: latestPatch`, so any `10.0.3xx` patch at or above `10.0.300` is used and anything else fails fast. All projects target `net10.0`.
- **Framework:** ABP `10.6.0`; LeptonX Lite theme `5.4.0` (previously a floating `5.4.0-preview*`, now pinned so a clean build resolves the same package everywhere); `RabbitMQ.Client` `7.1.2`.
- **Clean build:** `dotnet build src/FlashSale.OrderService.slnx --no-incremental` builds all five projects (three services, event contracts, tests).
- **Migrations:** each service migrates with its own account (`--migrate-database`, connection string from `ConnectionStrings__Default`). Order Service writes `order_service` and ABP's `public` tables; Inventory Service writes only `inventory_service`.

- **Signing certificate:** outside the Development environment, Order Service loads OpenIddict's certificate from `src/FlashSale.OrderService/openiddict.pfx`. `*.pfx` is git-ignored, so a fresh clone does not have it and Order Service stops at startup with `Signing Certificate couldn't found: openiddict.pfx`. Create it once with `scripts/create-openiddict-cert.ps1` (ABP's `dotnet dev-certs` command; local development value).

`scripts/verify-environment.ps1 -Mode Fresh` checks all of this on a brand-new database: the SDK against `global.json`, the certificate, the clean build, both migrations, Order Service starting and answering HTTP under its own account, account isolation and the ERD.

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

## Running the application on the local stack

The full, in-order reproduction, ending with `scripts/verify-runtime-accounts.ps1` (TP-E04):

1. Bring up the dependencies:
   ```powershell
   docker compose -f infra/docker-compose.yml up -d
   ```
2. On an **existing** volume only — a fresh volume runs `infra/initdb` automatically — apply the role script once so the service accounts and schema owners exist:
   ```powershell
   Get-Content -Raw .\infra\initdb\01-create-service-roles.sql | docker compose -f .\infra\docker-compose.yml exec -T postgres psql -v ON_ERROR_STOP=1 -U flashsale -d flashsale
   ```
3. Run each service's migrations under its own account, once, from `src/`:
   ```powershell
   dotnet run --project FlashSale.OrderService --migrate-database
   dotnet run --project FlashSale.InventoryService --migrate-database
   ```
4. Create the signing certificate (a fresh clone has no `openiddict.pfx`):
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\create-openiddict-cert.ps1
   ```
5. Warm up the inventory for the products you will order (defaults to the demo products):
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\warm-up.ps1
   ```
6. Run the three services, each from the repository root:
   ```powershell
   dotnet run --project src\FlashSale.OrderService
   dotnet run --project src\FlashSale.InventoryService
   dotnet run --project src\FlashSale.ProcessWorker
   ```
7. Order Service serves the API at `https://localhost:44314/api/orders` (self-signed in Development, so use `curl.exe -k`).
8. Each service runs under its own database account and schema: Order Service is `order_service_user` over `order_service` (plus ABP's `public` tables); Inventory Service is `inventory_service_user` over `inventory_service`; a service is denied any other service's schema. The Process Worker has **no database** by design — its `appsettings.json` has no `ConnectionStrings` section.
9. Verify the whole runtime:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\verify-runtime-accounts.ps1
   ```

## AWS deployment boundary

The teacher brief constrains backend services to one AWS EC2 host and JMeter to a separate machine. C4 replicas are processes or containers on that same host. Do not expose PostgreSQL, Redis, RabbitMQ management, Prometheus, or Grafana publicly for the experiment; make the API available only to the load-test source that needs it.

Week 12 box 3 adds the offline deployment artifacts: the three service `Dockerfile`s (SDK `10.0.300` to build, `aspnet:10.0.8` to run, `ASPNETCORE_URLS=http://+:8080`), `infra/docker-compose.ec2.yml` (only Nginx publishes a host port, migrations run once as one-shot services, credentials and C3 switches from the git-ignored `infra/ec2.env`, committed example `infra/ec2.env.example`), `infra/prometheus.ec2.yml`, `infra/terraform/` (local state, provider pinned, region `us-east-1`, `flashsale-ec2-ssm` profile referenced as a data source), `tests/jmeter/deploy-smoke-test.jmx`, and `docs/deployment.md` (the runbook). `scripts/verify-deployment.ps1` (TP-L03) checks all of this offline. No AWS resources have been created by this project change.

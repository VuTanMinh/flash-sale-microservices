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

## PostgreSQL ownership

- `flashsale` is the local bootstrap/admin account only.
- `order_service_user` owns `order_service` and receives the `public` schema access required by Order Service's ABP tables.
- `inventory_service_user` owns `inventory_service` and has no access to `order_service`.
- The role and schema SQL is mounted under `infra/initdb/` and is applied automatically only when PostgreSQL initializes a fresh `pgdata` volume. On an existing volume, apply it once with:

  ```powershell
  Get-Content -Raw .\infra\initdb\01-create-service-roles.sql | docker compose -f .\infra\docker-compose.yml exec -T postgres psql -v ON_ERROR_STOP=1 -U flashsale -d flashsale
  ```

On an existing dedicated project database, this script also transfers existing public tables and sequences to the Order Service account and service-schema objects to their respective service accounts, so later migrations can alter them. The committed credentials are local development values. Override service connection strings and bootstrap credentials for any non-local deployment.

## AWS deployment boundary

The teacher brief constrains backend services to one AWS EC2 host and JMeter to a separate machine. C4 replicas are processes or containers on that same host. Do not expose PostgreSQL, Redis, RabbitMQ management, Prometheus, or Grafana publicly for the experiment; make the API available only to the load-test source that needs it. Terraform and an EC2 deployment runbook are still required before the final submission; no AWS resources have been created by this project change.

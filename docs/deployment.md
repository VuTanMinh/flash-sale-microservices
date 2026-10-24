# EC2 deployment runbook (Week 12 box 3)

This is the runbook for the **offline half** of the box: one EC2 backend host runs
PostgreSQL, Redis, RabbitMQ, Nginx, the three services, Prometheus and Grafana
with Docker Compose; a second EC2 host runs JMeter. Nothing here is run against
AWS in this offline task — `terraform plan`/`apply` and the Docker builds are the
owner's/Claude's steps. The Terraform and Compose files are validated offline
first (`scripts/verify-deployment.ps1`, TP-L03).

Security model: the only inbound hole is **TCP 80 on the backend, from the JMeter
security group only**. No SSH, no `0.0.0.0/0` ingress, no NAT gateway, no Elastic
IP, no load balancer, no managed services. All access is through SSM Session
Manager with the existing instance profile **`flashsale-ec2-ssm`** (created by
hand by the owner; referenced as a data source, never created in Terraform).

The gateway (`infra/nginx.conf`) proxies only the API under test and returns 404
for everything else, so the ABP admin UI, identity endpoints, swagger and
`/metrics` are not reachable through Nginx (Prometheus scrapes the services
directly). The ABP admin user is still seeded with the template's default
password — a known value — so keeping that UI behind a 404 is intentional.

## 0. Prerequisites (owner, once)

- Region is locked to **`ap-southeast-2`** (Sydney) by the account's Free plan;
  nothing may be created in another Region.
- AWS CLI v2 with two profiles: `flashsale-plan` (an IAM user with a read-only
  access key, configured by the owner) and `flashsale-deploy` (the owner's own
  temporary login session, ~12 h; there is no IAM Identity Center / SSO and no
  attached guardrail policy). The Session Manager plugin
  (`session-manager-plugin`) must be installed locally.
- Terraform ≥ 1.9 (Claude validates with
  `E:\terraform_1.16.6_windows_amd64\terraform.exe`; use `-TerraformExe` in the
  verifier).
- The instance profile `flashsale-ec2-ssm` already exists (owner-created).
- The `week1-2` branch is pushed to GitHub (per Part A4 the owner pushes when
  they say so). Both EC2 hosts clone from there.

## 1. Certificate decision (Order Service, non-Development)

Outside `Development`, Order Service loads OpenIddict's signing/encryption
certificate from `openiddict.pfx` (`OrderServiceModule.cs`, `AddProductionEncryptionAndSigningCertificate`).
It is **not baked into the image**: `*.pfx` is excluded by the root
`.dockerignore`, and the EC2 Compose mounts it read-only at
`/app/openiddict.pfx`.

Why we mount it and run in `Production` rather than run the backend in
`Development`: `Development` would avoid the file (ABP auto-provisions a dev
certificate), but it would also turn on the developer exception page and the
physical-file/embedded-file fallback on the very host whose latency and
throughput Week 13/14 are measuring — a "production" measurement should not run
a "development" environment, and the certificate is one cheap mount. The file is
created on the backend with the pinned SDK image (step 4), so nothing binary is
copied over SSM.

## 2. Validate Terraform (offline, read-only profile)

```bash
cd infra/terraform
terraform init                      # writes .terraform.lock.hcl (commit it)
terraform fmt -check -recursive
terraform validate
terraform plan -var-file=terraform.tfvars   # profile: flashsale-plan (read-only)
```

The `plan` is read-only and must be run with the read-only profile. Do not run
`apply` with the read-only profile.

## 3. Owner applies (deploy profile)

```bash
cd infra/terraform
terraform apply -var-file=terraform.tfvars   # profile: flashsale-deploy
terraform output backend_private_ip
terraform output jmeter_private_ip
```

Note the two private IPs for the next steps.

**Safety timer (default 4 h).** Each instance schedules `shutdown -h +240` at
boot (`auto_terminate_minutes`, default `240`) and Terraform sets
`instance_initiated_shutdown_behavior = "terminate"`, so a forgotten session
powers the host off and AWS terminates it. This is only a safety net. Change the
window at apply time with `-var auto_terminate_minutes=...` (30–720). It does
not remove the security groups — `terraform destroy` is still the normal way to
clean up.

## 4. Prepare the backend (over SSM)

Open a session on the backend (`<backend-id>` from `terraform output backend_instance_id`):

```bash
aws ssm start-session --target <backend-id> --profile flashsale-deploy
```

Inside the session (run as root or `sudo -i`):

```bash
# 4a. Clone the repo (the branch the owner pushed in step 0).
cd /opt
git clone -b week1-2 https://github.com/VuTanMinh/flash-sale-microservices
cd flash-sale-microservices

# 4b. Create the (git-ignored) env file from the committed example, then set
#     real, distinct values for every CHANGE_ME. The two service-account
#     passwords must be real secrets -- generate each on this host:
#       openssl rand -base64 24
#     (initdb-ec2/02-service-roles-passwords.sh applies them over the dev
#      values in infra/initdb/01-create-service-roles.sql).
cp infra/ec2.env.example infra/ec2.env
vi infra/ec2.env

# 4c. Create the OpenIddict signing certificate on the host using the pinned
#     SDK image (no local .NET SDK needed). The passphrase is the one already
#     committed in OrderServiceModule.cs / scripts/create-openiddict-cert.ps1.
cd infra
docker run --rm -v "$PWD:/certs" -w /certs mcr.microsoft.com/dotnet/sdk:10.0.300 \
  dotnet dev-certs https -ep /certs/openiddict.pfx -p 99426be9-e087-4c7d-b9cb-566835df936d
# The container writes the pfx as root with mode 0600; the app runs as UID 1654, so make the mount readable.
chmod 0644 openiddict.pfx
cd ..

# 4d. Build the three service images (the Compose build contexts point at them).
docker compose --env-file infra/ec2.env -f infra/docker-compose.ec2.yml build

# 4e. Bring the stack up. Migrations run once (one-shot services), then the
#     services start. Only Nginx publishes a host port (80).
docker compose --env-file infra/ec2.env -f infra/docker-compose.ec2.yml up -d
docker compose -f infra/docker-compose.ec2.yml ps
```

PostgreSQL runs `infra/initdb/01-create-service-roles.sql` and
`infra/initdb-ec2/02-service-roles-passwords.sh` automatically on first init
(fresh `pgdata` volume). On a re-used volume, apply both once:

```bash
docker compose -f infra/docker-compose.ec2.yml exec -T postgres \
  psql -U flashsale -d flashsale -v ON_ERROR_STOP=1 < infra/initdb/01-create-service-roles.sql
# The password-override init script only runs on a fresh volume; re-apply it so
# the service-account passwords match infra/ec2.env.
docker compose -f infra/docker-compose.ec2.yml exec -T postgres \
  bash /docker-entrypoint-initdb.d/02-service-roles-passwords.sh
```

## 5. Warm up inventory and set the C3 bound (on the backend)

```bash
# 5a. Warm up (equivalent of scripts/warm-up.ps1 on Linux): open flash-product-1
#     with 1000 units and confirm the read-back.
docker exec infra-redis-1 redis-cli EVAL \
  "if ARGV[2] ~= '1' and redis.call('EXISTS', KEYS[3]) == 1 then return 'ALREADY_OPEN' end redis.call('SET', KEYS[1], ARGV[1]) redis.call('DEL', KEYS[2]) redis.call('SET', KEYS[3], '1') return 'OK'" \
  3 inventory:flash-product-1 processed:flash-product-1 sale:open:flash-product-1 1000 0

# 5b. C3 queue bound (optional; off == C2). The same script works locally and
#     on the backend: with no published 15672 it applies the policy with
#     rabbitmqctl inside the container (no port, no password).
pwsh -File scripts/set-queue-bounds.ps1 -Container infra-rabbitmq-1 -MaxLength 5
pwsh -File scripts/set-queue-bounds.ps1 -Container infra-rabbitmq-1 -Inspect
#     Without pwsh, the equivalent plain command:
docker exec infra-rabbitmq-1 rabbitmqctl set_policy flashsale-c3-bounds \
  '^(OrderPlaced|StockReserved|StockRejected|ProcessWorker\.StockReserved|OrderProcessingStarted|OrderProcessed)$' \
  '{"max-length": 5, "overflow": "reject-publish"}' --apply-to queues --priority 0

# 5c. Check that Prometheus scrapes all three services (each must say "up").
#     Prometheus has no host port; ask it from inside its container:
docker compose -f infra/docker-compose.ec2.yml exec -T prometheus \
  wget -qO- http://localhost:9090/api/v1/targets \
  | grep -o '"job":"[a-z-]*"\|"health":"[a-z]*"' | paste - -
```

Expected: `order-service`, `inventory-service`, `process-worker` and
`prometheus`, each `"health":"up"`. Before the fix in `docker-compose.ec2.yml`
(the Worker's `Urls` setting), `process-worker` was down: the Worker listened
on its own loopback (Week 12 run: "Connection refused (172.18.0.7:8080)").
This check has **not yet been run on EC2** after the fix.

## 6. Smoke test from the JMeter host

Open a session on the JMeter host and clone the repo (it needs only the JMX):

```bash
aws ssm start-session --target <jmeter-id> --profile flashsale-deploy
# in the session:
cd /opt
git clone -b week1-2 https://github.com/VuTanMinh/flash-sale-microservices
cd flash-sale-microservices
/opt/jmeter/bin/jmeter -n \
  -t tests/jmeter/deploy-smoke-test.jmx \
  -Jhost=<backend-private-ip> -Jport=80 -Jproduct=flash-product-1 \
  -l /tmp/deploy-smoke.jtl -j /tmp/deploy-smoke.log
```

The plan POSTs 5 orders through Nginx (`/api/orders`), asserts each returns
**201**, then polls `GET /api/orders/{id}` until the state is terminal and
asserts the final state is `Completed` or `Rejected`. With a warmed product all
5 reach `Completed`. A non-201, a 404/500 poll, or a state still not terminal
after ~40 polls (20 s) fails the run.

Also verify the isolation boundary the box is about: from the JMeter host the
backend's internal ports (5432, 5672, 15672, 6379, 9090, 3000) must be
**closed** — only port 80 answers. This is the live check the verifier stubs out
(`scripts/verify-deployment.ps1`, section "LIVE").

## 7. Evidence to save

Copy into `tests/evidence/` and commit (Part A4: `git add -f` for the log):

- the JMeter JTL and log (`/tmp/deploy-smoke.jtl`, `/tmp/deploy-smoke.log`);
- `terraform plan` output and the `terraform output` listing;
- `docker compose -f infra/docker-compose.ec2.yml ps` and
  `docker compose ... config` output;
- the verifier run: `scripts/verify-deployment.ps1 -TerraformExe <path>`.

## 8. Tear down the same day, then check for leftovers

```bash
# On the backend: stop and remove the stack and its volumes.
docker compose -f infra/docker-compose.ec2.yml down -v

# Locally: destroy the resources (deploy profile).
cd infra/terraform
terraform destroy -var-file=terraform.tfvars   # profile: flashsale-deploy

# Leftover check: no instances, security groups, volumes or the SSM-managed
# profile should remain. Confirm in the console (or with the read-only profile:
# aws ec2 describe-instances --filters "Name=tag:Project,Values=flash-sale").
```

The same-day `destroy` plus the leftover check is required: these are
per-experiment hosts, not long-lived infrastructure (DEC-D02 option A).

## 9. Overload run on EC2 (Week 12 box 4)

Run this after the smoke test (step 6) and before the tear down (step 8). The
backend `user_data` now also installs **git** and **PowerShell 7** (pinned,
`powershell-7.4.20-1.rh.x86_64.rpm`) so the collector and extractor can run on
the host; the JMeter `user_data` now also installs **git** and downloads JMeter
from `dlcdn.apache.org` (falling back to `archive.apache.org`), verifying
Apache's **SHA-512** before extracting.

1. **On the JMeter host**, run the three-phase plan against the backend's
   private IP (same phase values as locally; fixed at the Week 13 pilot):

   ```bash
   /opt/jmeter/bin/jmeter -n -t tests/jmeter/overload-recovery.jmx \
     -Jhost=<backend-private-ip> -Jport=80 -Jproduct=flash-product-1 \
     -JbaselineRate=3 -JoverloadRate=60 -JrecoveryRate=3 \
     -JbaselineDuration=30 -JoverloadDuration=60 -JrecoveryDuration=60 \
     -Jsample_variables=idempotencyKey \
     -l /tmp/overload.jtl -j /tmp/overload-jmeter.log
   ```

   Then build JMeter's own statistics dashboard:

   ```bash
   /opt/jmeter/bin/jmeter -g /tmp/overload.jtl -o /tmp/overload-report
   ```

2. **On the backend**, run the collector with `pwsh` across the run, stop it
   once the backlog has drained, then extract the numbers (the collector/
   extractor endpoints on the EC2 stack are finalised with the Week 13 pilot):

   The services publish no host port, so the collector reads their
   `/metrics` on the Compose network addresses, and RabbitMQ through
   `rabbitmqctl` in its container (no management port, no password; the
   publish/deliver/ack rates are then recorded `unavailable`):

   ```bash
   ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
   pwsh -File scripts/collect-run-metrics.ps1 -RunId ec2-overload -OutDir /tmp/overload -DurationSeconds 0 \
     -RabbitMqContainer infra-rabbitmq-1 -RedisContainer infra-redis-1 -PostgresContainer infra-postgres-1 \
     -OrderMetricsUrl "http://$(ip infra-order-service-1):8080/metrics" \
     -InventoryMetricsUrl "http://$(ip infra-inventory-service-1):8080/metrics" \
     -WorkerMetricsUrl "http://$(ip infra-process-worker-1):8080/metrics" &
   # after the drain: touch /tmp/overload/STOP, then
   pwsh -File scripts/extract-run-metrics.ps1 -RunId ec2-overload -RunDir /tmp/overload \
     -JtlPath /tmp/overload.jtl -Container infra-postgres-1 \
     -StableRange @{ max_p95_ms=1000; max_error_pct=0.0; max_refused_pct=0.0; min_throughput_per_s=1.0 }
   ```

3. **Evidence to save**: the JMeter JTL and log (`/tmp/overload.jtl`,
   `/tmp/overload-jmeter.log`), the `overload-report` dashboard, the collector's
   `samples.csv`/`collector.json`, and the extractor's
   `summary.json`/`stage-intervals.csv`. **Copy them back before
   `terraform destroy`**: the Week 12 EC2 overload run kept only its console
   summary (`tests/evidence/20261022T163505Z-ec2-overload.log`); its raw JTL and
   samples were lost with the instances. There is no SSH and no S3 here, and an
   SSM Run Command result is truncated at 24,000 characters, so copy each file
   as `gzip | base64` split into 20,000-character chunks
   (`split -b 20000`), read every chunk with one Run Command, join them locally
   and check the `sha256sum` printed on the host before destroying.

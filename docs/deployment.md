# EC2 deployment runbook

One EC2 backend host runs PostgreSQL, Redis, RabbitMQ, Nginx, the three services,
Prometheus and Grafana with Docker Compose; a second EC2 host runs JMeter.
`terraform apply` and `destroy` are the owner's steps. The Terraform and Compose
files are validated offline first (`scripts/verify-deployment.ps1`, TP-L03).

For a session, follow **0a** first, then sections 2 to 6, the config table in
**5f**, and the matrix in **11**.

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
- The `main-test-bug-fix` branch is pushed to GitHub (per Part A4 the owner pushes when
  they say so). Both EC2 hosts clone from there.

## 0a. Day-of checklist (owner, before each session)

1. Create the tfvars file if it is not there. It is git-ignored and holds no secret:

   ```bash
   cd infra/terraform
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Log in the deploy profile (the temporary session lasts about 12 h) and confirm it:

   ```bash
   aws login --profile flashsale-deploy
   aws sts get-caller-identity --profile flashsale-deploy
   ```

3. Check that the instance profile still exists:

   ```bash
   aws iam get-instance-profile --instance-profile-name flashsale-ec2-ssm --profile flashsale-deploy
   ```

4. Check that the commit you mean to run is on GitHub. The hosts clone
   `main-test-bug-fix`, so an unpushed commit is not what they run.
5. Size the safety timer. Each host terminates itself after 4 h by default, and
   anything not copied back goes with it. For a longer session, add
   `-var auto_terminate_minutes=<minutes>` (30 to 720) to `terraform apply`. A
   matrix takes about (load + drain + 1 min) per run, so count it before you start.
6. After section 6, run the live check in **11a** before any number counts.

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
git clone -b main-test-bug-fix https://github.com/VuTanMinh/flash-sale-microservices
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
docker compose --env-file infra/ec2.env -f infra/docker-compose.ec2.yml exec -T prometheus \
  wget -qO- http://localhost:9090/api/v1/targets \
  | grep -o '"job":"[a-z-]*"\|"health":"[a-z]*"' | paste - -
```

Expected: `order-service`, `inventory-service`, `process-worker`, `rabbitmq`
and `prometheus`, each `"health":"up"`. Before the fix in `docker-compose.ec2.yml`
(the Worker's `Urls` setting), `process-worker` was down: the Worker listened
on its own loopback (Week 12 run: "Connection refused (172.18.0.7:8080)").
Run on EC2 on 2026-10-24 (code `45486aa`): all four targets `up`, the Worker's
`/metrics` answered 200, `set-queue-bounds.ps1` applied the policy through
`rabbitmqctl` and the collector ran in container mode
(`tests/evidence/20261024T104902Z-ec2-overload.log`).

## 5d. C4 replicas (Week 13)

C4 is C3 run with 1, 2 or 4 Inventory replicas on the same host. `inventory-service`
has no `container_name`, so `--scale inventory-service=N` starts N replicas named
`infra-inventory-service-1`, `-2`, ...:

```bash
docker compose --env-file infra/ec2.env -f infra/docker-compose.ec2.yml up -d --scale inventory-service=4
```

PostgreSQL's `max_connections` is raised to 200 by default (see
`infra/docker-compose.ec2.yml` postgres.command and `PG_MAX_CONNECTIONS` in
`infra/ec2.env.example`) so 60 (Order) + 4 x 30 (Inventory) = 180 plus headroom
fits; the per-service pool sizes are unchanged. Prometheus scrapes every replica
through `dns_sd_configs` in `infra/prometheus.ec2.yml`.

The collector's `-InventoryMetricsUrl` is a single parameter, so pass every
replica as ONE comma-separated string. Build it AFTER scaling (replica IPs change
on every scale):

```bash
ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
docker compose --env-file infra/ec2.env -f infra/docker-compose.ec2.yml ps inventory-service
INV_URLS=$(for c in $(docker compose --env-file infra/ec2.env -f infra/docker-compose.ec2.yml ps -q inventory-service); do printf 'http://%s:8080/metrics\n' "$(ip "$c")"; done | paste -sd, -)
echo "$INV_URLS"   # e.g. http://172.18.0.5:8080/metrics,http://172.18.0.6:8080/metrics
```

## 5e. Log rotation

The root volume is 30 GiB and the services log per order, so every service in
`infra/docker-compose.ec2.yml` (the one-shot migrations included) uses the
`x-logging` anchor: `json-file` with `max-size: 50m` and `max-file: 3`. A
container therefore keeps at most ~150 MB of `docker logs` (3 × 50 MB); when a
fourth file would be written the oldest is deleted. Copy any log evidence
(`docker logs`, the collector's `samples.csv`/`collector.json`, JMeter's JTL)
back before it rotates, because a long run can rotate a busy service's logs
several times.

## 5f. Per-config setup (Week 13)

Set the whole row before every run. **Leaving C3 or C4 is the trap:**
`reset-and-seed.ps1 -Full` purges the queues but keeps the RabbitMQ policy, so
the next C1 or C2 run stays bounded unless the policy is removed.
`scripts/run-matrix.ps1` (section 11) applies this table and reads every value
back. The commands below are for a run by hand.

| Config | Path (`-Jpath`) | Queue bound | `ADMISSION_ENABLED` | `ORDER_RATE` / `ORDER_BURST` | Inventory replicas | Validator `-Config` |
| --- | --- | --- | --- | --- | --- | --- |
| C1 | `/api/c1/orders` | removed (`-Remove`) | `false` | `10000r/s` / `5000` | 1 | `C1` |
| C2 | `/api/orders` | removed (`-Remove`) | `false` | `10000r/s` / `5000` | 1 | `C2` |
| C3 | `/api/orders` | set (`-MaxLength <n>`) | `true` | `200r/s` / `100` | 1 | `C3` |
| C4, 1 replica | `/api/orders` | set (`-MaxLength <n>`) | `true` | `200r/s` / `100` | 1 | `C4` |
| C4, 2 replicas | `/api/orders` | set (`-MaxLength <n>`) | `true` | `200r/s` / `100` | 2 | `C4` |
| C4, 4 replicas | `/api/orders` | set (`-MaxLength <n>`) | `true` | `200r/s` / `100` | 4 | `C4` |

Every other limit stays in `infra/ec2.env`: `ADMISSION_MAX_CONCURRENT_NEW_ORDERS`,
`ADMISSION_MAX_OUTBOX_BACKLOG`, `ADMISSION_MAX_IN_FLIGHT_ORDERS` and
`PROCESSING_MAX_CONCURRENCY` are the same for every config. The C3 values of `n`,
the gateway limit and those limits are pilot results (Week 13), so the table
shows the current defaults. C1 and C2 have no gateway limit to study, so theirs
sits far above any offered rate.

By hand, as root in the repo, for C2 after C3 or C4:

```bash
# The shell wins over --env-file. Admission and the gateway are read at start.
ADMISSION_ENABLED=false ORDER_RATE=10000r/s ORDER_BURST=5000 \
  docker compose --env-file infra/ec2.env -f infra/docker-compose.ec2.yml up -d --scale inventory-service=1
# Nginx keeps the address it resolved at start, so it follows Order Service.
ADMISSION_ENABLED=false ORDER_RATE=10000r/s ORDER_BURST=5000 \
  docker compose --env-file infra/ec2.env -f infra/docker-compose.ec2.yml up -d --no-deps --force-recreate nginx
pwsh -File scripts/set-queue-bounds.ps1 -Container infra-rabbitmq-1 -Remove
# Gate: exits 1 if the bound is still on the broker. Do not start the load if it does.
pwsh -File scripts/set-queue-bounds.ps1 -Container infra-rabbitmq-1 -ExpectMaxLength 0
```

For C3 and C4, use the row's values, `-MaxLength <n>` in place of `-Remove`, and
`-ExpectMaxLength <n>` as the gate.

## 6. Smoke test from the JMeter host

Open a session on the JMeter host and clone the repo (it needs only the JMX):

```bash
aws ssm start-session --target <jmeter-id> --profile flashsale-deploy
# in the session (you are ssm-user): `git clone` into /opt and docker need root
sudo -i
cd /opt
git clone -b main-test-bug-fix https://github.com/VuTanMinh/flash-sale-microservices
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
   `rabbitmqctl` in its container (no management port, no password). Pass
   `-RabbitMqMetricsUrl` (the broker's Prometheus endpoint, port 15692, no
   credentials) so the publish/deliver/ack rates are computed as counter
   deltas instead of being recorded `unavailable`. With C4 replicas, pass every
   replica as ONE comma-separated `-InventoryMetricsUrl` (see section 5d):

   ```bash
   ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
   INV_URLS=$(for c in $(docker compose --env-file infra/ec2.env -f infra/docker-compose.ec2.yml ps -q inventory-service); do printf 'http://%s:8080/metrics\n' "$(ip "$c")"; done | paste -sd, -)
   pwsh -File scripts/collect-run-metrics.ps1 -RunId ec2-overload -OutDir /tmp/overload -DurationSeconds 0 \
     -RabbitMqContainer infra-rabbitmq-1 -RabbitMqMetricsUrl "http://$(ip infra-rabbitmq-1):15692/metrics" \
     -RedisContainer infra-redis-1 -PostgresContainer infra-postgres-1 \
     -OrderMetricsUrl "http://$(ip infra-order-service-1):8080/metrics" \
     -InventoryMetricsUrl "$INV_URLS" \
     -WorkerMetricsUrl "http://$(ip infra-process-worker-1):8080/metrics" &
   # after the drain: touch /tmp/overload/STOP, then
   pwsh -NoProfile -Command "& ./scripts/extract-run-metrics.ps1 -RunId ec2-overload -RunDir /tmp/overload -JtlPath /tmp/overload.jtl -Container infra-postgres-1 -StableRange @{ max_p95_ms=1000; max_error_pct=0.0; max_refused_pct=0.0; min_throughput_per_s=1.0 }"
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

## 10. Detached runs (Week 13)

An SSM session ends after ~20 idle minutes, so **never run JMeter or the
collector in the foreground** of an SSM session — a long load run would die with
it. Run them detached and keep a handle so you can check, follow and stop each
one. Two equivalent forms below: `nohup` (interactive SSM session) and
`systemd-run --unit=` (SSM Run Command, which otherwise has no shell that stays
alive across the command's lifetime).

The SSM session user is `ssm-user`; `git clone` into `/opt` and `docker` need
root, so `sudo -i` first, then `cd /opt/flash-sale-microservices`. SSM Run
Command does **not** start in the repo either: `systemd-run` starts a transient
service in `/` with no `HOME`, so give it
`--working-directory=/opt/flash-sale-microservices` (and `--setenv=HOME=/root`
for `pwsh`). `--collect` removes the unit as soon as it ends, so `systemctl
status <unit>` then reports "not found"; use `journalctl -u <unit>` to see its
output.

Every `-Products`/`-StableRange` hashtable must go through `pwsh -NoProfile
-Command "& ./scripts/... -Products @{ 'key' = value }"` (a quoted key,
repo-relative path): `pwsh -File` cannot pass a hashtable and a bare
`key = value` hash literal is a parse error.

Before every run (backend, as root in the repo): confirm the auto-terminate
timer, wait for cloud-init, then reset + seed + warm up. After the run, run the
validator.

```bash
# backend pre-run (the repo is already cloned at /opt/flash-sale-microservices)
sudo -i
cd /opt/flash-sale-microservices
cloud-init status --wait
shutdown --show
pwsh -File scripts/reset-and-seed.ps1 -Container infra-postgres-1 -Full \
  -RedisContainer infra-redis-1 -RabbitMqContainer infra-rabbitmq-1
pwsh -NoProfile -Command "& ./scripts/warm-up.ps1 -Container infra-redis-1 -Products @{ 'flash-product-1' = 1000 } -Force"

# ... run the load (below) ...

# backend post-run validator (C4 == the C2/C3 checks). Use the config you ran:
# with -RabbitMqContainer, C1 and C2 also fail if the queue bound is on the broker.
pwsh -File scripts/validate-correctness.ps1 -Config C4 -ProductId flash-product-1 -InitialStock 1000 \
  -PgContainer infra-postgres-1 -RedisContainer infra-redis-1 -RabbitMqContainer infra-rabbitmq-1
```

### JMeter, detached

```bash
# JMeter host, as root in the repo. HEAP is JMeter's own JVM-heap variable.
sudo -i
cd /opt/flash-sale-microservices
export HEAP="-Xms1g -Xmx2g"

# form 1 -- interactive SSM session (nohup; the pid is for checking only)
nohup /opt/jmeter/bin/jmeter -n -t tests/jmeter/workload.jmx \
  -Jhost=<backend-private-ip> -Jport=80 -Jpath=/api/orders -JproductsFile=products.csv \
  -Jmode=open -Jthreads1=50 -Jrate1=50 -Jduration1=60 -Jsample_variables=idempotencyKey \
  -l /tmp/run.jtl -j /tmp/run-jmeter.log > /tmp/run.out 2>&1 &
echo $! > /tmp/run.pid
cat /tmp/run.pid                      # check: the wrapper pid
tail -f /tmp/run.out                  # follow
pkill -f ApacheJMeter.jar             # stop (jmeter.sh runs java without exec, so $! is the wrapper)

# form 2 -- SSM Run Command (systemd-run --unit; --working-directory so the relative JMX path resolves)
systemd-run --unit=jmeter-run --collect --working-directory=/opt/flash-sale-microservices \
  env HEAP="-Xms1g -Xmx2g" /opt/jmeter/bin/jmeter -n -t tests/jmeter/workload.jmx \
  -Jhost=<backend-private-ip> -Jport=80 -Jpath=/api/orders -JproductsFile=products.csv \
  -Jmode=open -Jthreads1=50 -Jrate1=50 -Jduration1=60 -Jsample_variables=idempotencyKey \
  -l /tmp/run.jtl -j /tmp/run-jmeter.log
journalctl -u jmeter-run -f            # follow (--collect removed the unit once it ended)
```

### Collector, detached

The collector runs until you drop a `STOP` file (`-DurationSeconds 0`). Start it
before the load and stop it after the drain, with the separate block below. Build
the replica URL list AFTER scaling (replica IPs change on every scale).

```bash
# backend, as root in the repo.
sudo -i
cd /opt/flash-sale-microservices
ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
INV_URLS=$(for c in $(docker compose --env-file infra/ec2.env -f infra/docker-compose.ec2.yml ps -q inventory-service); do printf 'http://%s:8080/metrics\n' "$(ip "$c")"; done | paste -sd, -)
echo "$INV_URLS"                      # one comma-separated list of every replica

# form 1 -- interactive SSM session (nohup; the pid is for checking only)
nohup pwsh -File scripts/collect-run-metrics.ps1 -RunId run1 -OutDir /tmp/run1 -DurationSeconds 0 \
  -RabbitMqContainer infra-rabbitmq-1 -RabbitMqMetricsUrl "http://$(ip infra-rabbitmq-1):15692/metrics" \
  -RedisContainer infra-redis-1 -PostgresContainer infra-postgres-1 \
  -OrderMetricsUrl "http://$(ip infra-order-service-1):8080/metrics" \
  -InventoryMetricsUrl "$INV_URLS" \
  -WorkerMetricsUrl "http://$(ip infra-process-worker-1):8080/metrics" > /tmp/run1.out 2>&1 &
echo $! > /tmp/run1.pid
tail -f /tmp/run1.out                 # follow

# form 2 -- SSM Run Command (systemd-run --unit; --working-directory so the relative script path resolves, --setenv=HOME for pwsh)
systemd-run --unit=collector-run1 --collect --working-directory=/opt/flash-sale-microservices --setenv=HOME=/root \
  pwsh -File scripts/collect-run-metrics.ps1 -RunId run1 -OutDir /tmp/run1 -DurationSeconds 0 \
  -RabbitMqContainer infra-rabbitmq-1 -RabbitMqMetricsUrl "http://$(ip infra-rabbitmq-1):15692/metrics" \
  -RedisContainer infra-redis-1 -PostgresContainer infra-postgres-1 \
  -OrderMetricsUrl "http://$(ip infra-order-service-1):8080/metrics" \
  -InventoryMetricsUrl "$INV_URLS" \
  -WorkerMetricsUrl "http://$(ip infra-process-worker-1):8080/metrics"
journalctl -u collector-run1 -f       # follow (--collect removed the unit once it ended)
```

**Run this only to stop the collector**, after the load has ended and the backlog
has drained. It ends the collector at once, so never paste it with the blocks above:

```bash
touch /tmp/run1/STOP
```

## 11. The run matrix (Week 13)

`scripts/run-matrix.ps1` runs configs x load levels x repeats. For each run it
applies the row from section 5f, resets, seeds and warms up, checks the gates,
starts the collector, sends one `workload.jmx` load with `-Jmode=open`, waits for
the drain, validates, dumps the database and writes one `manifest.json`. It stops
at the first run that fails. C4 runs once for each of `-Replicas`.

Run it from your PC, not inside a host: it drives both hosts over SSM Run Command,
so a closed session cannot end it, and it needs `flashsale-plan` to be allowed
`ssm:SendCommand`.

```powershell
powershell -File .\scripts\run-matrix.ps1 -Transport Ssm -BackendInstance <backend-id> -JMeterInstance <jmeter-id> -BackendHost <backend-private-ip> -Configs C1,C2,C3,C4 -Rates 50,200 -Repeats 1 -OutDir <local-folder>
```

- **A failed gate** means the stack is not the config the run claims, and no load
  is sent. The manifest names the gate under `prepare.gates`.
- **The achieved rate** is in `load.achieved_per_s`. A shortfall is a result and
  does not fail the run; report the achieved rate.
- **Where the files are:** `manifest.json` is on your PC. `raw.jtl` is on the
  JMeter host, and the collector files, `validator.log` and `db.dump` are on the
  backend, each under `/tmp/matrix/<run-id>/`. Copy them back before
  `terraform destroy`, as in section 9.
- **Latency breakdown:** the run keeps the database rows in `db.dump` because the
  next reset wipes them. Running `extract-run-metrics.ps1` on those dumps is not
  automated yet.

### 11a. Live check at the start of the first session

The SSM path cannot be tested offline. Case G of `verify-ec2-stack.ps1` proves the
same steps on a local stack through the `Local` transport only, so run this short
matrix before any measured run:

```powershell
powershell -File .\scripts\run-matrix.ps1 -Transport Ssm -BackendInstance <backend-id> -JMeterInstance <jmeter-id> -BackendHost <backend-private-ip> -Configs C3,C2,C1 -Rates 5 -DurationSeconds 20 -Stock 1000 -OutDir <local-folder>
```

It must print `MATRIX PASS: 3 run(s).`, and it covers the moves that matter: C3 to
C2 removes the bound, and C1 runs through Nginx. Then, on the backend:

```bash
# Every target "up", as in step 5c (order, inventory, worker, rabbitmq, prometheus).
docker compose --env-file infra/ec2.env -f infra/docker-compose.ec2.yml exec -T prometheus \
  wget -qO- http://localhost:9090/api/v1/targets \
  | grep -o '"job":"[a-z-]*"\|"health":"[a-z]*"' | paste - -
```

Also check that the collector's `samples.csv` on the backend holds numeric rows for
the services, not `unavailable`: the local test cannot reach those endpoints. If
anything here fails, stop and fix it. These three runs are a check, not pilot data.

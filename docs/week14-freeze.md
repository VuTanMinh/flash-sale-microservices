# Week 14 freeze manifest

This file fixes what the official Week 14 runs use (Week 13 box 2). Every value
is read from the repository or the evidence at freeze time, and
`scripts/verify-freeze.ps1` (TP-X09) checks each one against its source file.
If a value here and its source disagree, the verifier fails and the freeze is
not valid until one of them is corrected.

The owner signed off the run values on 4 November 2026, after the EC2
confirmation (`tests/evidence/20261104T132500Z-ec2-confirmation/summary.log`).

## 1. Source

| Item | Value |
| --- | --- |
| Frozen source commit | `9ff2e1a5d8c694d44802f1f783dc1778e515b795` (the parent of the commit that adds this file) |
| Branch | `main-test-bug-fix` |

Only documentation and evidence may change after this commit for the official
runs. A change to `src/`, `infra/`, `tests/jmeter/` or `scripts/` makes the
freeze invalid until this manifest is updated and re-verified.

## 2. Infrastructure

| File | SHA-256 (file with LF line endings, as git stores it) |
| --- | --- |
| `infra/terraform/main.tf` | `a915ae3adf4e65fae5208da0053fd6348a2db0e3beda498cb1618dc2ed67b92b` |
| `infra/terraform/variables.tf` | `902df52839363f1d937780a64a5e27e4834bd42b9e96e6ad37f445cd84627a83` |
| `infra/terraform/versions.tf` | `c6a272ddd0894e21102d4b55b35781f15763e681110e622e3946c57fc19cdc92` |
| `infra/terraform/outputs.tf` | `216f59f77d169d4772bc4cea75ccd93d2e45e9aa8ac4391710fbe643ef6344b2` |
| `infra/terraform/.terraform.lock.hcl` | `625bd2cdad3e1bd2c337217630e4c2ddcd3fba8c5ab918dbeb331444820efa26` |
| `infra/terraform/terraform.tfvars.example` | `1da17adb7148dbd406070651dd98ba339a486ef3cbb78810efa9516e9091b1bf` |

| Item | Value | Source |
| --- | --- | --- |
| Region | `ap-southeast-2` | `variables.tf`, `aws_region` default |
| Availability zone | `ap-southeast-2a` | `variables.tf`, `availability_zone` default |
| Backend instance type | `m7i-flex.large` (2 vCPU) | `variables.tf`, `backend_instance_type` default |
| JMeter instance type | `c7i-flex.large` | `variables.tf`, `jmeter_instance_type` default |
| Root volume | 30 GiB | `variables.tf`, `root_volume_size_gb` default |
| AMI | latest Amazon Linux 2023 from the SSM parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64` at apply time | `main.tf` |
| AWS provider | `hashicorp/aws` 5.100.0 | `versions.tf`, `.terraform.lock.hcl` |
| Terraform required | `>= 1.9.0` | `versions.tf` |

The AMI is resolved when `terraform apply` runs, not pinned: two applies on
different days can boot different Amazon Linux 2023 images.

## 3. Tool and runtime versions

| Tool | Version | Source |
| --- | --- | --- |
| .NET SDK | 10.0.300 (`rollForward: latestPatch`) | `global.json` |
| .NET runtime in the images | `mcr.microsoft.com/dotnet/aspnet:10.0.8` | the three `src/*/Dockerfile` |
| .NET SDK in the image build | `mcr.microsoft.com/dotnet/sdk:10.0.300` | the three `src/*/Dockerfile` |
| JMeter (JMeter host) | 5.6.3, SHA-512 checked at install | `main.tf`, `JMETER_VERSION` |
| JMeter (this PC) | 5.6.3 | `D:\tools\apache-jmeter-5.6.3` |
| Java (JMeter host) | `java-17-amazon-corretto-headless` from `dnf`, minor version not pinned | `main.tf` |
| Docker Compose plugin (backend) | v2.29.7 | `main.tf`, `DOCKER_COMPOSE_VERSION` |
| Docker engine (backend) | `docker` from `dnf`, version not pinned and not recorded | `main.tf` |
| PowerShell (backend) | 7.4.20 | `main.tf`, `PWSH_VERSION` |
| Terraform (this PC) | v1.16.6 | `terraform version` at freeze |
| AWS CLI (this PC) | 2.38.2 | `aws --version` at freeze |
| Docker (this PC) | 29.8.1, Compose v5.5.1 | `docker version` at freeze |

## 4. Images

The EC2 Compose file pins every third-party image by tag. The digest below is
the registry's index digest for that tag when this file was written. A tag can
be moved later; if it is, the digest here no longer matches what a new apply
pulls.

| Image | Index digest at freeze |
| --- | --- |
| `postgres:16.14` | `sha256:95206741a5b214807675e14165369d05b93a9cf692223b616d07cca227e74b0b` |
| `redis:7.4.7` | `sha256:976ab0f0939b78c06d802bcd3bea44c5142ea9a756a57b861e08819817f768c8` |
| `rabbitmq:3.13.7-management` | `sha256:e582c0bc7766f3342496d8485efb5a1df782b5ce3886ad017e2eaae442311f69` |
| `nginx:1.31.3` | `sha256:8541484afbc9c8a5a8a99b379568ebbc957f658583ec9448fc43104229c03cf8` |
| `prom/prometheus:v3.14.0` | `sha256:5ce7540c3c00ef4ab0c9d2c995c6a5b9c421f44b4a115d97a2c7af3b1c21cbb0` |
| `grafana/grafana:13.2.2` | `sha256:ac461fb352abc50da10a51c7d02462e9c05488f11f53f14b3ad79a8145f638a0` |
| `mcr.microsoft.com/dotnet/sdk:10.0.300` (build) | `sha256:c0790639332692a0d56cdd81ed581cfd24d040d9839764c138994866df89a3b6` |
| `mcr.microsoft.com/dotnet/aspnet:10.0.8` (runtime) | `sha256:8c0b6857eab7b2aa57884c839bf4678414606bd7d17370f18a842ac5cf414711` |

The three service images (`flashsale-order-service:10.0`,
`flashsale-inventory-service:10.0`, `flashsale-process-worker:10.0`) are built
on the backend from the frozen commit and the base images above. They have no
registry digest. Each run's manifest records the image id it ran
(`prepare.images` in `manifest.json`).

## 5. Workload

| Item | Value | Source |
| --- | --- | --- |
| Plan | `tests/jmeter/workload.jmx`, `-Jmode=open` (submit only) | `run-matrix.ps1` |
| Load levels | 50, 100 and 200/s for C1 to C4; 400/s for C3 and C4 only | owner sign-off; `run-matrix.ps1 -Rates` default `50, 100, 200` |
| Configurations | C1, C2, C3, C4; C4 at 1, 2 and 4 Inventory replicas | `run-matrix.ps1 -Configs` and `-Replicas` defaults |
| Load per run | 60 s | `run-matrix.ps1 -DurationSeconds` default |
| Repeats | 3 | `run-matrix.ps1 -Repeats` default |
| Threads | `max(20, rate)` | `run-matrix.ps1` |
| Product | `flash-product-1` (`tests/jmeter/products.csv`), stock 100,000 | `run-matrix.ps1 -Product`, `-Stock` defaults |
| Reset | full reset, seed and warm-up before every run | `run-matrix.ps1` prepare step |

**Seeds: there are none.** JMeter draws nothing from a seeded generator. Each
submission's `Idempotency-Key` is a fresh `__UUID()`, so keys differ every run.
Product ids come from a CSV Data Set read in order and recycled
(`recycle=true`), so the product sequence is the same every run. Pacing is a
Constant Throughput Timer, which is deterministic. Run-to-run variation
therefore comes from timing on the hosts, not from the plan.

## 6. Process Worker

| Item | Value | Source |
| --- | --- | --- |
| Processing delay | 200 ms per order | `src/FlashSale.ProcessWorker/appsettings.json`, `Processing:DelayMilliseconds`; `ProcessingOptions.cs` default |
| Worker concurrency | 20 | `infra/ec2.env.example`, `PROCESSING_MAX_CONCURRENCY` |
| Worker prefetch | 20 | `infra/ec2.env.example`, `WORKER_PREFETCH` |

## 7. Shedding and retry limits

| Limit | Value | Source |
| --- | --- | --- |
| Gateway rate limit (C3, C4) | 200 requests/s, burst 100 | `run-matrix.ps1 -ShedOrderRate`, `-ShedOrderBurst` defaults; `infra/ec2.env.example` |
| Gateway for C1, C2 | 10000 requests/s, burst 5000 (no limit to study) | `run-matrix.ps1 -OpenOrderRate`, `-OpenOrderBurst` defaults |
| Admission, concurrent new orders | 64 | `infra/ec2.env.example`, `ADMISSION_MAX_CONCURRENT_NEW_ORDERS` |
| Admission, Outbox backlog | 2000 | `infra/ec2.env.example`, `ADMISSION_MAX_OUTBOX_BACKLOG` |
| Admission, unfinished orders | 0 (off) | `infra/ec2.env.example`, `ADMISSION_MAX_IN_FLIGHT_ORDERS` |
| Queue bound (C3, C4) | 1000 messages, `reject-publish` | `run-matrix.ps1 -QueueMaxLength` default; `set-queue-bounds.ps1` |
| Order Service consumer concurrency | 4 | `infra/ec2.env.example`, `ORDER_CONSUMER_CONCURRENCY` |
| Inventory consumer concurrency | 1 | `infra/ec2.env.example`, `INVENTORY_CONSUMER_CONCURRENCY` |
| Consumer prefetch (Order, Inventory) | 20 | `RabbitMqOptions.cs` defaults in both services |
| Worker publish attempts | 4 (1 + 3 retries, 1/2/4 s) | `StockReservedConsumer.cs`, `MaxAttempts`, `RetryDelays` |
| Handler retries (Order, Inventory consumers) | 4 attempts, 1/2/4 s | `StockResultConsumer.cs`, `OrderProcessingStartedConsumer.cs`, `OrderProcessedConsumer.cs`, `OrderPlacedConsumer.cs` |
| Outbox publisher retries (both services) | 4 attempts, 1/2/4 s; batch 50 | both `OutboxPublisherWorker.cs` |
| Delayed requeue, early completion | 2/4/8 s, then dead letter | `OrderProcessedConsumer.cs` and `OrderProcessingStartedConsumer.cs`, `RequeueDelays` |
| Reconciliation stuck timeout | 120 s | `infra/ec2.env.example`, `RECONCILIATION_STUCK_TIMEOUT_SECONDS` |
| Reconciliation attempts | 3 | `ReconciliationOptions.cs`, `MaxAttempts`; Order Service `appsettings.json` |
| Reconciliation poll | 30 s | `ReconciliationOptions.cs`, `PollIntervalSeconds` |
| Reconciliation, Confirmed or Processing | 300 s | Order Service `appsettings.json`, `ProcessingStuckTimeoutSeconds` |
| PostgreSQL connections | 200 | `infra/ec2.env.example`, `PG_MAX_CONNECTIONS` |

## 8. Metric definitions

| Metric | Definition | Source |
| --- | --- | --- |
| Achieved rate | (submissions - 1) / (last submit time - first submit time), from the JTL submit rows | `run-matrix.ps1`, `achieved_per_s` |
| HTTP p95 | Nearest-rank 95th percentile (rank `ceil(0.95 n)`) of `elapsed` over 2xx submit rows | `run-matrix.ps1`, `http_ms`; `extract-run-metrics.ps1` |
| End-to-end p95 | Nearest-rank 95th percentile of `CompletedAt - RequestAcceptedAt` over the run's orders | `extract-run-metrics.ps1`, `accepted_to_completed` |
| Drain | Seconds after the load ends until no order is outside Completed or Rejected and no Outbox row is unpublished in either service | `run-matrix.ps1`, post step |
| Retries | Reset-aware increase of `flashsale_consumer_retries_total` over the run | `extract-run-metrics.ps1`, `counters.retries` |
| Dead letters | Reset-aware increase of `flashsale_consumer_dead_lettered_total` only, so each dead letter counts once | `extract-run-metrics.ps1`, `counters.dead_lettered` |
| Duplicates | Reset-aware increase of `flashsale_consumer_duplicates_total` | `extract-run-metrics.ps1`, `counters.duplicates` |
| Reconciliations | Reset-aware increase of `flashsale_reconciliation_retriggers_total` plus `flashsale_reconciliation_given_up_total` | `extract-run-metrics.ps1`, `counters.reconciliation` |
| Correctness | `validate-correctness.ps1` exit 0, checks 1 to 6 | per run, `validator.log` |

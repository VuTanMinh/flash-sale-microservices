# Flash-Sale Microservices Capstone

Thiết kế và đánh giá hệ thống microservices xử lý giao dịch song song trong kịch bản flash-sale — TDTU.

**Students:** Vũ Đình Kiệt (523V0011) and Vũ Tấn Minh (523V0012) — Class 23K50201 — TDTU  
**Roadmap:** 08/08–21/11 (15 weeks)

## Project scope and design

The report is in `report/`: the LaTeX source, its figures, and the built
`report/report.pdf` and `report/progress/progress-report.pdf`. The design
documents are in `docs/`.

- [Reproduce the results on a fresh machine](docs/reproduction.md)
- [Requirement-to-evidence index](docs/evidence-index.md)
- [Midterm review: what was found and how each finding was resolved](docs/midterm-review-disposition.md)
- [Test plan (every test case, its inputs, expected result and log)](docs/test-plan.md)

- [Scope and research questions](docs/00-scope-lock.md)
- [Service boundaries and event flow](docs/service-boundaries.md)
- [Order state machine](docs/order-state-machine.md)
- [Inventory invariants](docs/inventory-invariants.md)
- [Experiment protocol](docs/experiment-protocol.md)
- [Local infrastructure and AWS target](docs/infrastructure.md)
- [EC2 deployment runbook](docs/deployment.md)
- [OpenAPI export](docs/api-contract-v1.json)
- [Capstone report (PDF)](report/report.pdf) and [progress report (PDF)](report/progress/progress-report.pdf)

## Repository layout

| Path | Purpose |
|---|---|
| `src/` | Order Service, Inventory Service, Process Worker, and event contracts |
| `infra/` | Docker Compose (local and `docker-compose.ec2.yml`), Nginx, and `terraform/` for the AWS EC2 deployment |
| `scripts/` | Database reset/seed, warm-up, validation, verifiers, metric collection/extraction, and Redis Lua |
| `tests/` | .NET tests, JMeter plans, and `evidence/` (saved verifier logs and run data) |
| `docs/` | Scope, architecture, correctness, experiment, API, reproduction and evidence documents |
| `report/` | LaTeX report, figures and the built PDFs (report and progress report) |

## Quickstart

For a full reproduction from a clean machine, follow [docs/reproduction.md](docs/reproduction.md). To run the local stack and the three services by hand, follow [Local infrastructure — Running the application on the local stack](docs/infrastructure.md#running-the-application-on-the-local-stack). In short: Compose up, apply the role script on an existing volume, migrate with each service's own account, create the certificate, warm up, then `dotnet run` each service. The own-account runtime is verified by `scripts/verify-runtime-accounts.ps1`. The AWS EC2 deployment required by the brief (one backend host, JMeter on a separate host) is in `infra/terraform/` with `infra/docker-compose.ec2.yml`; its runbook is [docs/deployment.md](docs/deployment.md).

# Flash-Sale Microservices Capstone

Thiết kế và đánh giá hệ thống microservices xử lý giao dịch song song trong kịch bản flash-sale — TDTU.

**Students:** Vũ Đình Kiệt (523V0011) and Vũ Tấn Minh (523V0012) — Class 23K50201 — TDTU  
**Roadmap:** 08/08–21/11 (15 weeks)

## Project scope and design

- [Scope and research questions](docs/00-scope-lock.md)
- [Service boundaries and event flow](docs/service-boundaries.md)
- [Order state machine](docs/order-state-machine.md)
- [Inventory invariants](docs/inventory-invariants.md)
- [Experiment protocol](docs/experiment-protocol.md)
- [Local infrastructure and AWS target](docs/infrastructure.md)
- [OpenAPI export](docs/api-contract-v1.json)
- [Capstone report](report/report.tex)

## Repository layout

| Path | Purpose |
|---|---|
| `src/` | Order Service, Inventory Service, Process Worker, and event contracts |
| `infra/` | Docker Compose and service configuration |
| `scripts/` | Database reset/seed, warm-up, validation, and Redis Lua |
| `tests/` | .NET tests and JMeter plans/results |
| `docs/` | Scope, architecture, correctness, experiment, and API documents |
| `report/` | LaTeX report and bibliography |

## Quickstart

Run the local stack and the three services exactly as described in [Local infrastructure — Running the application on the local stack](docs/infrastructure.md#running-the-application-on-the-local-stack): Compose up, apply the role script on an existing volume, migrate with each service's own account, create the certificate, warm up, then `dotnet run` each service. The own-account runtime is verified by `scripts/verify-runtime-accounts.ps1`. The teacher brief also requires Terraform and AWS EC2 deployment; Terraform is not present in this branch yet.

# Flash-Sale Microservices — notes for Claude

.NET 10 / ABP microservices (Order, Inventory, Process Worker) with PostgreSQL,
Redis, RabbitMQ and Nginx. Capstone project; the report is `report/report.tex`.

## Rules
- **All roadmap work follows `.claude/skills/checkbox-build/SKILL.md`.**
  It holds the hard Notion rule: only the "05 — 15-Week Roadmap and Submission"
  page may be read or written; no other Notion page, database or workspace.
- The plan lives in that Notion page, not in local markdown.
- The teacher's requirements are in `docs/teacher-brief.md` (verbatim); results must satisfy them.
- One checkbox at a time; tick only with verified evidence.
- Env files (`.env`, `.env.*`, `*.env`) are always in `.gitignore`, even before any exist; never commit secrets.

## Commands
- Infra: `docker compose -f infra/docker-compose.yml up -d`
- Build: `dotnet build src/FlashSale.OrderService.slnx`
- Tests: `dotnet test tests/FlashSale.OrderService.Tests`
- Reset/seed: `pwsh scripts/reset-and-seed.ps1`; correctness: `powershell -File scripts/validate-correctness.ps1 -Config C1|C2 -ProductId <id> -InitialStock <n>`

## Best-practice references
- https://github.com/shanraisshan/claude-code-best-practice
- https://claudelog.com/

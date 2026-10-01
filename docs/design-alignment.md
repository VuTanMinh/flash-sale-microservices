# Design alignment (Week 4)

Every design artifact must map to real code or to an explicitly open task (roadmap W04). This table records, per artifact, what it is checked against and how. `scripts/verify-design-alignment.ps1` runs the automated checks.

**Requirements source:** `docs/teacher-brief.md`. **Order states:** the teacher's six-state model adopted on 2026-10-01 (`docs/order-state-machine.md`). Where the code does not yet implement part of that model, the artifact must say so and name the task that will.

| Artifact | File | Checked against (source) | How it is verified | Open parts (explicit task) |
|---|---|---|---|---|
| ERD | `docs/erd.md` | EF models + migrations, `baseline-schema.sql`, role script | `scripts/verify-erd.ps1` against a live DB (29 checks) | Order status-history table: Week 11 |
| Class diagram | `docs/class-diagram.md` | `Entities/*.cs` in Order and Inventory Service, `FlashSale.EventContracts/*.cs` | every class and property in the diagram exists in that file with that type, and every public property in those files is in the diagram | `Processing` enum value and `OrderProcessingStartedEto`: Week 11 |
| API contract | `docs/api-contract-v1.json` (OpenAPI, exported from the running service) | `OrdersController`, `BaselineOrdersController` | each order endpoint's documented status codes equal the `[ProducesResponseType]` codes in the controller; the file is a fresh export of the current build | None (quantity = 1 validation added and verified in Week 5, TP-A02) |
| Event contracts | `docs/event-contract.md` | `FlashSale.EventContracts/*.cs`, publishers/consumers, `appsettings.json` routing | every field table equals the class's public properties (name + type); routing keys and exchange match the code | `OrderProcessingStartedEto`: Week 11 |
| Teacher state model | `docs/order-state-machine.md` | `docs/teacher-brief.md` §5, `OrderState.cs`, `Order.cs` | all six states named; the four implemented transitions equal `Order.LegalTransitions`; the doc states the code gap | `Processing`/history: Week 11 |
| Sequence diagrams | `docs/sequence-diagrams.md` | controllers, Outbox workers (2 s poll), consumers, `reserve.lua`, Process Worker | status codes, routing keys, poll interval and states in the diagrams match the code; no claim that `Processing` does not exist | `OrderProcessingStarted` hop: Week 11; Nginx routing: Week 12 |

## Not claimed

- Nginx routing in the sequence diagrams is target design until Week 12.
- Inbox checks, retry and DLQ hops are omitted from the sequence diagrams on purpose; they are described in the event contract and the implementation chapters.

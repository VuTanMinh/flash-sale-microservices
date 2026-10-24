# Applying stock results in Order Service (Week 8)

Requirements: `docs/teacher-brief.md` §5 ("Order Service consume event kết quả và chuyển trạng thái order thành Confirmed hoặc Rejected. Business update và processed-message record được commit trong cùng một local transaction"). Tested by `scripts/verify-stock-results.ps1` (TP-W01) against the real consumer, and by `OrderStateBehaviourTests` (TP-A06).

| Event (queue) | Order state | Committed together |
|---|---|---|
| `StockReserved` (`StockReserved`) | `PendingStock → Confirmed`, `ConfirmedOrRejectedAt` stamped | order update + Inbox row (`processed_messages`, unique `MessageId`) in one `SaveChangesAsync` |
| `StockRejected` (`StockRejected`) | `PendingStock → Rejected`, `ConfirmedOrRejectedAt` stamped | same |

| Situation | Behaviour |
|---|---|
| Same message delivered again | Inbox hit, so acked; nothing changes |
| Same result as a new message (order already in that state, or past it) | Acked; Inbox row recorded; state and timestamp unchanged |
| Conflicting result (e.g. `StockRejected` for a `Confirmed` order) | Not retried; nacked to the queue's DLQ (`StockReserved.dlq` / `StockRejected.dlq`); nothing recorded |
| Unknown order id | Acked without action; nothing recorded |
| Inbox insert fails | The state change is rolled back with it (one transaction). Whether the message is then retried rather than acked is the database-exception rule (Week 8 box 3, `docs/design-decisions.md` §4) |

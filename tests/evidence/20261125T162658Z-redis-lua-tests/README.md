# reserve.lua tests against a real Redis (item 1, 25 November 2026)

New tests: `tests/FlashSale.InventoryService.Tests/ReserveLuaRedisTests.cs` (5 cases through
`InventoryReservationService.ReserveAsync`). They run when `FLASHSALE_TEST_REDIS` is set and
are skipped otherwise. CI runs them against a `redis:7` service container.

Run on a fresh clone on E: (`E:\Agent_Memory\DACNTT\fix-redis`, HEAD a79315b plus the new test
file and the ci.yml change), throwaway container `redis:7` on port 6421.

| Run | Result |
|---|---|
| Release build of `src/FlashSale.OrderService.slnx` | 0 warnings, 0 errors |
| Inventory tests, `FLASHSALE_TEST_REDIS` not set | Passed 3, Skipped 5, Total 8 |
| Inventory tests, `FLASHSALE_TEST_REDIS=localhost:6421` | Passed 8, Total 8 |
| Negative control: readiness check in `reserve.lua` disabled (`if false then`), output copy confirmed broken | Failed 1 (`Missing_open_marker_is_not_open`), Passed 7 |
| After reverting the break | Passed 8, Total 8 |

Cases: (a) open sale, stock 2: Reserved, stock 1, order in the processed set; (b) same order
again: Duplicate, stock unchanged; (c) stock 0: Rejected, nothing changed; (d) no sale-open
marker: NotOpen, stock unchanged, order not recorded; (e) stock 3, 10 concurrent orders: exactly
3 Reserved and 7 Rejected, stock 0, processed set of 3.

Note on the negative control: a first attempt wrote the break through a relative path that
.NET resolved against the shell's start folder, so it changed `D:\DACNTT\scripts\redis\reserve.lua`
instead of the scratch copy, and the scratch tests (correctly) still passed. The repository file
was restored with `git checkout` before any commit and is identical to HEAD. The control was then
rerun with absolute paths, with the result above.

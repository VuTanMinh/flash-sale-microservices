# Report material, 25 November 2026

Material for the report work from 26 November: tables and notes only. Nothing in
`report/report.tex` was changed for these items. Every number below comes from committed
evidence; the source and the method are given with each table.

## 1. RabbitMQ publish, deliver and ack rates (official runs)

The brief lists "RabbitMQ publish, delivery và acknowledgement rate" as a metric. It was
collected in all 66 official runs but not reported in the Results chapter. The values are
in each run's `summary.json` (`collector.broker_rates`), inside the per-repeat archives
`tests/evidence/20261105T104832Z-official/w14-rep{1,2,3}-backend.tgz`.

**Method.** On EC2 the collector read the broker's Prometheus endpoint (port 15692) every
5 s and turned the counters `rabbitmq_global_messages_received_total`, `..._delivered_total`
and `..._acknowledged_total` into per-second rates between samples
(`scripts/collect-run-metrics.ps1`, test case TP-L08). The extractor
(`scripts/extract-run-metrics.ps1`) reports the mean and the peak of those rates over all
samples of the run: the 60 s load **and** the drain until the matrix's drain check passed.
Messages per second, whole broker (all queues). Cells: median of 3 runs (range).

| Cell | Publish mean | Deliver mean | Ack mean | Publish peak | Deliver peak | Ack peak |
|---|---|---|---|---|---|---|
| C1 50/s | 0 (0-0) | 0 (0-0) | 0 (0-0) | 0 (0-0) | 0 (0-0) | 0 (0-0) |
| C1 100/s | 0 (0-0) | 0 (0-0) | 0 (0-0) | 0 (0-0) | 0 (0-0) | 0 (0-0) |
| C1 200/s | 0 (0-0) | 0 (0-0) | 0 (0-0) | 0 (0-0) | 0 (0-0) | 0 (0-0) |
| C2 50/s | 153 (151-161) | 189 (188-201) | 189 (189-202) | 243 (225-252) | 301 (282-317) | 302 (280-311) |
| C2 100/s | 204 (199-207) | 250 (246-266) | 250 (247-267) | 472 (428-476) | 513 (483-550) | 521 (485-577) |
| C2 200/s | 211 (199-214) | 261 (247-262) | 261 (247-262) | 566 (458-841) | 452 (418-507) | 449 (418-507) |
| C3 50/s | 153 (150-163) | 192 (189-203) | 192 (190-203) | 233 (231-244) | 341 (324-353) | 357 (324-361) |
| C3 100/s | 193 (62-200) | 227 (75-237) | 227 (75-237) | 403 (378-441) | 487 (473-518) | 493 (473-517) |
| C3 200/s | 40 (37-145) | 48 (44-173) | 48 (44-174) | 367 (343-404) | 456 (438-465) | 456 (438-467) |
| C3 400/s | 34 (33-35) | 42 (40-42) | 42 (40-42) | 303 (293-351) | 457 (457-516) | 457 (457-516) |
| C4 x1 50/s | 154 (146-164) | 191 (182-205) | 191 (183-204) | 243 (224-254) | 305 (282-305) | 300 (282-301) |
| C4 x1 100/s | 64 (61-66) | 76 (71-77) | 76 (71-77) | 408 (398-473) | 509 (479-510) | 510 (485-510) |
| C4 x1 200/s | 51 (40-138) | 61 (48-166) | 61 (48-167) | 358 (328-485) | 492 (491-533) | 497 (496-540) |
| C4 x1 400/s | 35 (35-133) | 43 (42-164) | 43 (42-164) | 361 (323-389) | 469 (450-479) | 474 (450-479) |
| C4 x2 50/s | 160 (154-166) | 202 (194-208) | 203 (195-209) | 277 (267-283) | 351 (346-363) | 341 (334-369) |
| C4 x2 100/s | 198 (58-201) | 235 (68-236) | 235 (68-235) | 341 (299-375) | 454 (431-520) | 454 (436-524) |
| C4 x2 200/s | 43 (42-149) | 49 (49-175) | 49 (49-175) | 340 (315-347) | 456 (429-483) | 462 (435-490) |
| C4 x2 400/s | 123 (123-125) | 153 (143-162) | 153 (143-163) | 367 (327-478) | 552 (457-602) | 565 (463-602) |
| C4 x4 50/s | 156 (149-160) | 201 (191-205) | 202 (192-205) | 252 (249-259) | 375 (313-388) | 379 (313-401) |
| C4 x4 100/s | 57 (57-194) | 66 (65-224) | 66 (65-224) | 312 (302-344) | 444 (440-461) | 447 (444-469) |
| C4 x4 200/s | 42 (36-42) | 49 (42-50) | 49 (42-50) | 316 (304-319) | 467 (444-469) | 473 (446-482) |
| C4 x4 400/s | 32 (32-32) | 38 (38-39) | 39 (38-39) | 309 (295-322) | 483 (475-484) | 489 (482-491) |

**Notes for the text.**
- C1 does not use the broker, so its rates are 0.
- Deliver and ack are above publish because one `StockReserved` publish is routed to two
  queues (Order Service and the Process Worker), so it is delivered twice.
- Ack equals deliver within rounding in every cell: every delivered message was acknowledged.
- The **mean** covers the load and the drain. In runs whose drain waited about 300 s for
  reconciliation (the dead-letter defect of Section 10.6), the quiet tail lowers the mean;
  that is why some cells have wide ranges (for example C3 at 100/s: 62 to 200). Checked per
  run: C3 100/s rep with drain 302 s had a mean of 62/s; the two reps with drains of 40-49 s
  had 193-200/s. C4 with 4 consumers at 100/s: drains 306-318 s gave 57/s, a 50 s drain gave 194/s.
- The **peak** is the better measure of what the broker carried: 233 to 566 publishes/s,
  highest for C2 at 200/s (566). The broker was never the limit; the backlog sat in the
  Order Service Outbox before publication (Results, "Where the time goes").

## 2. Workload profiles (TP-X04)

The brief lists these profiles. They were run once each on the EC2 Compose stack on a local
machine (C4, low rates), as coverage, not compared across configurations. Source:
`tests/evidence/20261031T161516Z-ec2-stack.log`, case E; parameters from
`scripts/verify-ec2-stack.ps1`.

| Profile (brief) | Load | Result | Correctness |
|---|---|---|---|
| Steady load | 10/s for 15 s, one product | 67 orders, every submission 2xx, orders in DB = 2xx submits | validator passed |
| Ramp-up | 5, 15 then 30/s, 10 s each | 135 orders, every submission 2xx | validator passed |
| Spike | 3, 40 then 3/s, 10 s each | 105 orders, every submission 2xx | validator passed |
| Sustained overload + recovery | 3, 60 then 3/s, 10 s each, low gateway limit | 82 requests refused with 429 in the overload stage; only 2xx in the recovery stage; backlog drained | validator passed after the drain |
| One hot product | 10/s for 15 s, `products-hot.csv` | 63 orders, every submission 2xx | validator passed |
| Skewed demand | 10/s for 15 s, 4 products at 70/15/10/5 % | every product got orders, the largest share went to the hot one: 46, 10, 7, 4 | validator (-Products) passed |
| Requests below inventory | 10 requests, 20 units | 10 reserved = min(requests, stock) | validator passed |
| Requests equal to inventory | 20 requests, 20 units | 20 reserved | validator passed |
| Requests above inventory | 30 requests, 20 units | 20 reserved, never more | validator passed |

**Correction needed in the report (Section 9.4, "Workload profiles").** The paragraph cites
`20261031T161516Z-ec2-stack.log` but says "86 requests in the overload stage were refused with
429". That log records `stage2_429=82`. The 86 comes from a second run on the same day,
`20261031T171915Z-ec2-stack.log`, which passed every check too and gives the same skew counts
(46, 10, 7, 4) and the same below/equal/above results. Either change 86 to 82, or keep 86 and
cite `20261031T171915Z-ec2-stack.log`. The table above uses the cited run (82).

## 3. Academic references for Related Work (checked online on 25 Nov 2026)

Each entry below was looked up and its bibliographic details confirmed before listing it.
They are not in the report yet; use the ones you want in Section 3.7 and add them to the
bibliography in the report's style.

1. **H. Garcia-Molina and K. Salem. Sagas.** In *Proceedings of the 1987 ACM SIGMOD
   International Conference on Management of Data*, pages 249–259, 1987.
   DOI 10.1145/38713.38742.
   *Summary:* a long-lived transaction is split into a sequence of smaller transactions
   that can interleave with others, with compensation instead of one global transaction.
   *Relation to this project:* the classic alternative to distributed transactions. Our
   order workflow is a saga-like sequence of local transactions (Order → Inventory → Order
   → Worker → Order) linked by events, except that it has no compensation step, because the
   Worker is success-only (the brief) and a rejected order simply ends `Rejected`.

2. **P. Helland. Life beyond Distributed Transactions: an Apostate's Opinion.** In
   *Proceedings of the 3rd Biennial Conference on Innovative Data Systems Research (CIDR)*,
   Asilomar, California, 2007. A shorter updated version appeared in *ACM Queue*.
   *Summary:* argues that distributed transactions are impractical at scale and that
   scalable applications should update one entity per transaction and talk to other
   entities by messages, which must then be processed idempotently.
   *Relation:* the design principle behind our schema-per-service, one local transaction per
   step, at-least-once messages and an Inbox for idempotence.

3. **M. Welsh, D. Culler and E. Brewer. SEDA: An Architecture for Well-Conditioned,
   Scalable Internet Services.** In *Proceedings of the 18th ACM Symposium on Operating
   Systems Principles (SOSP)*, Chateau Lake Louise, Canada, 2001.
   *Summary:* services built as stages connected by explicit queues, with admission control
   on each queue so that the service degrades gracefully under overload instead of being
   overcommitted.
   *Relation:* our C3 design is close to this: stages (Order, Inventory, Worker) joined by
   bounded queues, with admission control (503) and a gateway rate limit (429) so that
   overload is refused early. Our replicas result (more consumers on one host add
   contention) is consistent with SEDA's point that capacity is set by the shared resource,
   not by the number of stage threads.

4. **R. Laigner, Y. Zhou, M. A. V. Salles, Y. Liu and M. Kalinowski. Data Management in
   Microservices: State of the Practice, Challenges, and Research Directions.**
   *Proceedings of the VLDB Endowment*, 14(13):3348–3361, 2021. arXiv:2103.00170.
   *Summary:* a literature review, an analysis of open-source microservice applications and
   a survey of over 120 practitioners and researchers on how microservices manage data; the
   challenges it reports include managing constraints across distributed service states,
   weak concurrency isolation, data replication semantics and consistency across storage
   technologies.
   *Relation:* these are exactly the problems our Outbox, Inbox and per-service schemas
   address at application level, and it supports the report's point that this costs
   complexity (the failure-mode table has 22 cases).

None of these papers measures a flash-sale workload, so they support the design choices,
not the numbers. The Related Work section can still say honestly that published
descriptions of production flash-sale systems were not reviewed.

Sources checked: dblp/bibtex record of the SIGMOD 1987 paper; the CIDR 2007 PDF hosted at
UC Irvine and the ACM Queue version; the SOSP 2001 paper (Princeton and Michigan course
copies); the PVLDB/arXiv record of Laigner et al.

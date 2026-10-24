# Teacher brief (authoritative project requirements)

Recorded 2026-10-01 from the teacher's note, verbatim below. This is reference
context: the requirements the finished project must satisfy. The **execution
plan** is the Notion page "05 — 15-Week Roadmap and Submission". Follow Notion
for *what to do next and when to tick*, and this brief for *what the result
must satisfy*. When they conflict, flag it to the project owners instead of
picking silently.

Key points that later checkboxes must keep:

- Six order states: PendingStock, Confirmed, Rejected, Processing, Completed, ProcessingFailed (adopted 2026-10-01; see `docs/order-state-machine.md`).
- Schema-per-service on one PostgreSQL instance, with a separate database account per service and no cross-schema access.
- Process Worker: deterministic delay, success only, `order ID` as its idempotency key.
- Observability per order: correlation ID, order ID, message ID, current status, **state transition history**, and four timestamps (acceptance, event publication, stock processing, completion).
- C0–C4 configurations, workloads, metrics and correctness validation as listed in §6. Each configuration runs 3–5 times; report percentiles, median and variation, not just averages.
- Deliverables include Terraform, AWS EC2 deployment, raw data and a README that reproduces the environment and experiments.

---

1. Bối cảnh, lý do chọn đề tài và phát biểu bài toán
Trong các hệ thống E-commerce, Flash-sale tạo ra một dạng tải đặc thù: số lượng request tăng đột biến trong thời gian ngắn và thường tập trung vào một số sản phẩm có inventory giới hạn. Khi nhiều request đồng thời cạnh tranh trên cùng một sản phẩm, hệ thống phải giải quyết hai vấn đề chính.

Thứ nhất, việc nhiều transaction cùng cập nhật một inventory record có thể gây lock contention tại database, làm tăng response time và giảm throughput. Mặc dù relational database có thể bảo đảm tính đúng đắn thông qua atomic update hoặc transaction locking, hiệu năng có thể suy giảm khi mức contention tăng cao.

Thứ hai, nếu thao tác kiểm tra và cập nhật inventory không được thực hiện atomically, nhiều request có thể cùng đọc một giá trị trước khi dữ liệu được cập nhật, dẫn đến over-selling.

Ngoài ra, khi incoming request rate vượt quá processing capacity, hệ thống cần chủ động kiểm soát tải. Nếu tiếp nhận không giới hạn, queue có thể tăng liên tục, làm latency kéo dài và gây cascading failure.

Phát biểu bài toán: Cho một sản phẩm có inventory hữu hạn (N) và một luồng request đặt hàng đồng thời với tốc độ có thể vượt quá processing capacity, cần thiết kế và đánh giá một kiến trúc bảo đảm:

Số lượng stock reservation thành công không vượt quá initial inventory trong các test scenario.

Hệ thống phản hồi có kiểm soát khi overload thay vì tiếp nhận request không giới hạn.

Hệ thống hỗ trợ tăng số lượng consumer replica để cải thiện processing capacity trong giới hạn tài nguyên.

Trạng thái của mỗi order có thể được trace xuyên suốt asynchronous workflow.

Từ bài toán trên, nhóm đề xuất xây dựng và đánh giá một event-driven inventory reservation architecture sử dụng Redis Lua Script để xử lý inventory atomically và RabbitMQ để tách quá trình tiếp nhận order khỏi các bước xử lý phía sau.

Giải pháp được so sánh với một synchronous baseline sử dụng atomic update trên PostgreSQL. Mục tiêu không phải chứng minh Monolith hoặc relational database không thể xử lý inventory đúng, mà đánh giá sự khác biệt về latency, throughput, overload behavior và architectural complexity giữa hai cách tiếp cận.

2. Mục tiêu của đề tài
Đề tài tập trung giải quyết bốn bài toán kỹ thuật chính.

a) Asynchronous Event-Driven Processing
Order processing được tách thành các bước độc lập thông qua Message Broker. Khi tiếp nhận request, Order Service lưu order ở trạng thái PendingStock và ghi event OrderPlaced vào Transactional Outbox trong cùng một database transaction.

Một background publisher đọc Outbox và gửi event đến RabbitMQ. Inventory Service nhận event và xử lý stock reservation. Client nhận order ID để tiếp tục tra cứu trạng thái thay vì chờ toàn bộ workflow hoàn tất.

Thiết kế này giúp giảm thời gian giữ HTTP connection và tách request acceptance rate khỏi downstream processing rate. Đề tài đồng thời đo cả API response latency và thời gian để order đạt terminal state.

b) Inventory Consistency
Redis Lua Script được sử dụng để thực hiện atomically các thao tác:

kiểm tra idempotency;

kiểm tra available inventory;

trừ inventory nếu còn đủ;

ghi nhận kết quả reservation.

Hệ thống cần duy trì các invariant:

available_inventory >= 0;

số reservation thành công không vượt quá initial inventory;

một order chỉ có tối đa một reservation thành công;

duplicate message không tạo duplicate stock deduction.

Giải pháp Redis được so sánh với baseline dùng conditional atomic update trên PostgreSQL.

c) Load Shedding và Resilience
Hệ thống triển khai nhiều lớp overload protection, gồm rate limiting tại Nginx, concurrency limiting tại application và bounded queue tại RabbitMQ.

Khi đạt ngưỡng cấu hình, request mới được reject sớm bằng response code phù hợp thay vì tiếp tục làm queue tăng không kiểm soát. Hệ thống cũng sử dụng publisher confirm, bounded retry và Dead-Letter Queue để quản lý message failure.

Các chỉ số đánh giá bao gồm rejected request rate, queue depth, tail latency, backlog drain time và recovery time sau overload.

d) Observability và Performance Evaluation
Mỗi request, order và event được gắn correlation ID, order ID và message ID để hỗ trợ distributed tracing.

Đề tài đo ảnh hưởng của:

incoming request rate;

inventory implementation;

load shedding;

số lượng consumer replica;

mức contention trên inventory.

Kết quả được dùng để phân tích trade-off giữa consistency, latency, throughput, resilience và architectural complexity.

3. Phạm vi, đối tượng sử dụng và giới hạn
Phạm vi
Đề tài tập trung xây dựng backend cho Flash-sale order processing, gồm:

Order Service;

Inventory Service;

Process Worker mô phỏng downstream processing;

RabbitMQ;

Redis;

PostgreSQL;

Nginx;

logging và metrics;

load-testing environment.

Đề tài không xây dựng frontend hoàn chỉnh. Client behavior được mô phỏng bằng Apache JMeter thông qua các API tạo order và tra cứu trạng thái.

Các chức năng như product catalog, shopping cart, promotion, user management và administration không nằm trong phạm vi.

Đối tượng sử dụng
Trong phạm vi thực nghiệm, người dùng được mô phỏng bằng các load-test scenario đại diện cho nhiều khách hàng đồng thời đặt mua sản phẩm.

Kết quả có thể được sử dụng làm tài liệu tham khảo cho sinh viên, developer và software architect quan tâm đến inventory consistency, event-driven processing và overload handling.

Giới hạn
Các backend component được triển khai trên một AWS EC2 instance do giới hạn thời gian và chi phí. JMeter được chạy trên một máy riêng để tránh cạnh tranh tài nguyên với system under test.

Việc tăng số lượng replica được thực hiện ở mức process hoặc container trên cùng một host. Thực nghiệm này đánh giá consumer replication và shared-resource contention, nhưng không đại diện đầy đủ cho multi-node horizontal scaling.

Các service sử dụng chung một PostgreSQL instance nhưng có schema và database account riêng. Service không được truy cập trực tiếp schema của service khác. Đây là schema-per-service, chưa phải physical database isolation.

Process Worker chỉ mô phỏng downstream processing với deterministic delay và kết quả thành công. Payment failure, compensation, Redis Cluster, RabbitMQ Cluster, PostgreSQL replication và multi-region deployment không nằm trong phạm vi.

Authentication và Authorization cũng được loại khỏi đề tài vì không liên quan trực tiếp đến research objective.

4. Các chức năng và yêu cầu chính
Chức năng chính
Tiếp nhận và lưu order.

Trả order ID sau khi request được accepted.

Kiểm tra và reserve inventory atomically.

Cập nhật order status theo kết quả stock reservation.

Mô phỏng downstream processing.

Tra cứu trạng thái order thông qua polling API.

Publish và consume event qua RabbitMQ.

Sử dụng Transactional Outbox tại producer.

Sử dụng Inbox hoặc processed-message table tại consumer.

Retry message lỗi tạm thời và chuyển poison message vào Dead-Letter Queue.

Phát hiện order bị treo bằng reconciliation job.

Ghi timestamp và trạng thái tại từng processing stage.

Yêu cầu phi chức năng
Consistency
Trong tất cả workload và failure scenario được kiểm thử:

inventory không được âm;

số reservation thành công không vượt quá initial inventory;

một order không được reserve nhiều lần;

duplicate message không tạo duplicate side effect.

Performance
Hệ thống được đánh giá tại nhiều mức tải. Mỗi experiment phải ghi rõ:

EC2 configuration;

virtual users và request rate;

test duration;

số lượng sản phẩm;

initial inventory;

số consumer replica;

payload size;

cấu hình PostgreSQL, Redis và RabbitMQ.

Mục tiêu ban đầu là đạt khoảng 2.000 inventory reservation attempt mỗi giây trên cấu hình phần cứng được chọn. Đây là experimental target, không phải cam kết độc lập với deployment environment.

Resilience
Khi overload, hệ thống phải reject một phần request có kiểm soát thay vì tiếp nhận vô hạn. Sau khi tải giảm, backlog phải được xử lý hết và hệ thống trở lại trạng thái ổn định mà không cần restart toàn bộ.

Observability
Mỗi order phải được trace thông qua:

correlation ID;

order ID;

message ID;

current status;

state transition history;

request acceptance time;

event publication time;

stock processing time;

completion time.

5. Giải pháp đề xuất, kiến trúc và công nghệ
Hệ thống được thiết kế theo event-driven architecture. Mỗi service quản lý dữ liệu nghiệp vụ riêng và không truy cập trực tiếp dữ liệu của service khác.

Client gửi request qua Nginx. Nginx thực hiện rate limiting và chuyển request đến Order Service.

Order Service kiểm tra request và client idempotency key. Nếu request được accepted, service tạo order ở trạng thái PendingStock và ghi event OrderPlaced vào Outbox trong cùng một PostgreSQL transaction.

Sau khi transaction commit, service trả order ID cho client. Outbox Publisher gửi event đến RabbitMQ và sử dụng publisher confirm để xác nhận broker đã tiếp nhận message.

Inventory Service nhận OrderPlaced, kiểm tra Inbox hoặc processed-message table, sau đó gọi Redis Lua Script để kiểm tra và reserve inventory atomically.

Nếu thành công, Inventory Service phát StockReserved; nếu hết hàng, service phát StockRejected.

Order Service consume event kết quả và chuyển trạng thái order thành Confirmed hoặc Rejected. Business update và processed-message record được commit trong cùng một local transaction.

Process Worker nhận StockReserved, mô phỏng downstream processing và sử dụng order ID làm idempotency key để tránh duplicate side effect.

Client polling API cho đến khi order đạt terminal state hoặc timeout. Reconciliation job định kỳ kiểm tra các order ở trạng thái PendingStock quá lâu. Cơ chế này chỉ đóng vai trò safety net, không thay thế Outbox, retry hoặc DLQ.

Các cơ chế kỹ thuật chính
Transactional Outbox
Order và event được lưu trong cùng một database transaction. Outbox Publisher tiếp tục retry cho đến khi RabbitMQ xác nhận message đã được nhận.

Idempotent Consumer
Mỗi message có một message ID duy nhất. Consumer lưu message ID bằng unique constraint. Domain update và Inbox record được commit trong cùng một transaction.

Nếu consumer crash sau khi commit nhưng trước acknowledgement, message có thể được redeliver nhưng side effect không được thực hiện lại.

Retry và Dead-Letter Queue
Transient failure được retry với số lần giới hạn. Message vượt quá retry limit được chuyển vào DLQ để tránh poison message chặn main queue.

Load Shedding
Nginx giới hạn request rate, application giới hạn concurrency và RabbitMQ sử dụng bounded queue với overflow policy phù hợp.

Request bị reject trước khi order được tạo nếu hệ thống không còn khả năng tiếp nhận. Hệ thống không trả accepted status cho một request nếu không có cơ chế bảo đảm workflow tiếp tục được xử lý.

Inventory Warm-up
Inventory được load vào Redis trước khi Flash-sale bắt đầu. Sản phẩm chỉ được mở bán sau khi warm-up hoàn tất và được xác nhận.

Order State Machine
Các trạng thái chính gồm:

PendingStock;

Confirmed;

Rejected;

Processing;

Completed;

ProcessingFailed.

Duplicate hoặc invalid event không được tạo state transition lặp.

Công nghệ sử dụng

| Thành phần | Công nghệ |
|---|---|
| Backend | ABP Framework, .NET/C# |
| Message Broker | RabbitMQ |
| Inventory reservation | Redis Stack, Lua Scripting |
| Database | PostgreSQL, schema-per-service |
| API Gateway | Nginx |
| Message reliability | Outbox, Inbox, Retry, DLQ |
| Observability | Structured Logging, correlation ID, metrics |
| Infrastructure | Docker Compose, Terraform |
| Deployment | AWS EC2 |
| Load Testing | Apache JMeter |

6. Phương pháp đánh giá và sản phẩm dự kiến
Các cấu hình thực nghiệm
C0 – Naïve implementation
Application đọc inventory, kiểm tra và cập nhật lại mà không có concurrency control phù hợp.

Cấu hình này chỉ dùng để minh họa race condition, không phải baseline chính.

C1 – PostgreSQL Atomic Baseline
Order được xử lý synchronously. Inventory được cập nhật bằng conditional atomic update trên PostgreSQL.

Cấu hình này phải bảo đảm không over-selling và được sử dụng làm baseline chính.

C2 – Redis Event-Driven
Order được xử lý asynchronously qua RabbitMQ. Inventory Service sử dụng Redis Lua Script. Hệ thống có Outbox, Inbox, retry và idempotent consumer.

C3 – Load Shedding
C2 được bổ sung rate limiting, concurrency limiting và bounded queue để đánh giá overload behavior.

C4 – Consumer Replication
C3 được chạy với 1, 2 và 4 Inventory consumer replica trên cùng EC2 host để đánh giá throughput, queue drain time và shared-resource contention.

Workload
Các test profile gồm:

ramp-up;

steady load;

spike load;

sustained overload;

recovery period;

một hot product;

nhiều sản phẩm có skewed request distribution;

request volume nhỏ hơn, bằng và lớn hơn initial inventory.

Mỗi cấu hình được chạy nhiều lần với cùng điều kiện. Database và Redis được reset, seed và warm-up trước mỗi experiment.

Metrics
Nhóm thu thập:

API latency p50, p95 và p99;

stock-decision latency;

end-to-end completion latency;

incoming, accepted và completed throughput;

rejected request rate;

internal error rate;

stock reservation success và rejection rate;

queue depth;

oldest message age;

backlog drain time;

recovery time;

retry và duplicate-message count;

DLQ message count;

pending order count;

CPU, RAM và database connection usage;

Redis latency;

RabbitMQ publish, delivery và acknowledgement rate.

API throughput và business completion throughput phải được báo cáo riêng.

Correctness Validation
Sau mỗi lần chạy, hệ thống tự động kiểm tra:

available_inventory >= 0;

successful_reservations <= initial_inventory;

mỗi order có tối đa một reservation thành công;

mỗi order chỉ tạo một downstream result;

accepted order phải đạt terminal state hoặc được reconciliation job phát hiện;

tổng số order theo trạng thái phải khớp với tổng số accepted request.

Phân tích kết quả
Mỗi configuration được chạy ít nhất từ ba đến năm lần. Báo cáo sử dụng percentile latency, median và mức biến động giữa các lần chạy thay vì chỉ dùng average.

Các kết luận được giới hạn trong workload, hardware configuration và failure model đã kiểm thử.

Sản phẩm dự kiến
Source code của các service.

Redis Lua Script.

Outbox và Inbox implementation.

RabbitMQ retry và DLQ configuration.

Nginx rate-limiting configuration.

Docker Compose và Terraform script.

JMeter test plan.

Script reset, seed và warm-up dữ liệu.

Raw experimental data.

Báo cáo phân tích và biểu đồ.

README hướng dẫn tái lập environment và experiment.

Roadmap 15 tuần

| Tuần | Thời gian dự kiến | Nội dung triển khai và báo cáo |
|---|---|---|
| 1 | 08/08–14/08 | Chốt scope, research questions, architecture, service boundaries, order state machine, workload, inventory invariants và experiment protocol. Tạo khung báo cáo; viết nháp Introduction, Problem Statement, Objectives, Scope và Limitations. |
| 2 | 15/08–21/08 | Thiết kế data model; setup repository, development environment, Docker Compose, PostgreSQL, Redis, RabbitMQ và Nginx. Viết nháp System Requirements, Technology Selection, Development Environment; bổ sung ERD và architecture notes. |
| 3 | 22/08–28/08 | Xây dựng C0 Naïve Implementation và C1 PostgreSQL Atomic Baseline; viết JMeter smoke test và script reset/seed dữ liệu. Viết phần baseline, race condition, atomic update và correctness criteria. |
| 4 | 29/08–04/09 | Hoàn thiện ERD, API contract, event contract, state machine và test plan. Hoàn thành bản nháp chương System Analysis and Design; bổ sung sequence diagram và design rationale. |
| 5 | 05/09–11/09 | Xây dựng Order Service: API tạo order, API tra cứu trạng thái, client idempotency key và state management. Viết phần Order Service, API design, idempotency strategy và test cases. |
| 6 | 12/09–18/09 | Xây dựng Transactional Outbox, Outbox Publisher, RabbitMQ integration và publisher confirm. Viết phần Event Publication Reliability, dual-write problem, Outbox workflow và failure scenarios. |
| 7 | 19/09–25/09 | Xây dựng Inventory Service, Redis Lua Script, inventory warm-up và xử lý OrderPlaced. Viết phần Inventory Reservation, Redis data structure, Lua logic và inventory invariants. |
| 8 | 26/09–02/10 | Hoàn thiện StockReserved/StockRejected workflow, cập nhật order status và correctness validation. Hoàn thành mô tả workflow chính và cập nhật sequence diagram theo implementation. |
| 9 | 03/10–09/10 | Xây dựng Inbox/processed-message table, idempotent consumer, acknowledgement strategy và duplicate-message test. Viết phần Message Delivery Semantics, Idempotent Consumer và duplicate handling. |
| 10 | 10/10–16/10 | Cấu hình bounded retry, Dead-Letter Queue, timeout handling và reconciliation job. Viết phần Failure Handling and Recovery; ghi rõ các failure mode được và chưa được hỗ trợ. |
| 11 | 17/10–23/10 | Xây dựng Process Worker mô phỏng downstream processing; hoàn thiện correlation ID, structured logging và metrics. Viết phần Observability, metric definitions và timestamp schema; chuẩn bị mẫu bảng và biểu đồ Results. |
| 12 | 24/10–30/10 | Triển khai Load Shedding tại Nginx, application và RabbitMQ; kiểm thử overload, queue overflow và recovery behavior. Viết phần Load Shedding Design, overload scenarios và pilot observations. |
| 13 | 31/10–06/11 | Thực hiện pilot testing với C1–C4; thử nghiệm 1, 2 và 4 consumer replica; phát hiện bottleneck và khóa source code, workload, infrastructure, metric definitions. Hoàn thiện Experimental Design và viết nháp Results từ pilot data. |
| 14 | 07/11–13/11 | Chạy toàn bộ official experiments, lặp lại mỗi configuration từ 3–5 lần; hoàn tất raw data, biểu đồ, Results, Discussion, Limitations, Conclusion, README và tài liệu tái lập. Cuối tuần 14 phải hoàn thành toàn bộ source code, testing, experiment và nội dung học thuật chính của báo cáo. |
| 15 | 14/11–21/11 | Chỉ chỉnh sửa hình thức và hoàn thiện hồ sơ: rà soát nội dung, kiểm tra số liệu và trích dẫn, kiểm tra đạo văn, chuẩn hóa định dạng, hoàn thiện biểu mẫu, chữ ký và phụ lục; đóng gói source code, dataset và tài liệu; nộp lên hệ thống trước hạn. Không phát triển chức năng mới hoặc thay đổi experiment configuration. |

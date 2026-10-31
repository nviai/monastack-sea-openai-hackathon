# Test các update task/agent trên macOS

Chạy từ repository root. Bản build: app/build/macos/Build/Products/Debug/monastack.app.
Mở bằng python3 tools/local_office.py start để app dùng node member 47840 và dữ liệu server 47830.
Không xóa database. Đăng nhập pha.le (admin); mật khẩu seed nếu chưa đổi:
NviaiSeaxOpenAIHackathon. Host mẫu bên dưới dùng actor le-pha tương ứng tài khoản này.

## 1. Task board

1. Mở Workspace tools → Open task board.
2. Bấm Project, tạo “Agent update test”, chọn Workspace để test voice công khai.
3. Chọn project, bấm Task, tạo ticket và chọn Atlas/Dev agent.
4. Kiểm tra ba cột To do / In progress / Done, số lượng từng cột.
5. Start → Done → Reopen: ticket di chuyển và số lượng cập nhật.
6. Comments: thêm bình luận, đóng/mở lại để kiểm tra lưu; History để xem lịch sử.

Gán assignee trên board chưa tự chạy worker. Để thực thi, bấm Agent proposal trên
card rồi nhập yêu cầu và bấm Propose. Đây vẫn là bước riêng trong phiên bản này.

## 2. Giao việc và tự tạo ticket

1. Workspace tools → Agent proposals.
2. Chọn Atlas (dev-agent), nhập yêu cầu, bấm Propose.
3. Mở board, chọn project “Agent assignments” mới: phải có ticket riêng tư tương ứng.
4. Quay lại Agent proposals → Approve: trạng thái Approved, waiting for host.
5. Không có worker thì trạng thái này đứng yên; đây không phải báo hoàn thành.

Mỗi giao việc không gắn ticket tạo một project riêng tư mới; tên project có thể trùng.

## 3. Thông báo và trả lời comment

1. Dùng project Workspace, tạo ticket bằng pha.le và giao cho một người khác.
2. Người nhận đăng nhập, vào ticket, thêm comment.
3. pha.le mở nút chuông Notifications ở bảng bên phải màn hình office.
4. Kiểm tra thông báo chứa tên ticket và comment; bấm để trả lời.
5. Bấm dấu tick để đánh dấu đã đọc; đóng/mở lại phải giữ trạng thái.

Tự comment ticket của chính mình không gửi thông báo lại cho mình.

## 4. Cấu hình kênh

1. Admin mở Notifications → Delivery settings.
2. Chọn Ticket + notifications hoặc Voice in current room + notification fallback.
3. Mở lại settings để kiểm tra giá trị đã lưu.
4. Tài khoản không phải admin không có nút này; API cũng từ chối thay đổi.

Lựa chọn hiện áp dụng chung, chưa tách riêng hỏi thông tin / hoàn thành / duyệt.

## 5. Chuẩn bị worker Codex cho bài test

Máy đã có Codex; dùng codex login status để kiểm tra đăng nhập. Tạo repository mẫu
để test, không dùng source ứng dụng làm checkout. Cấu hình này bật host claims của
workspace; chỉ chạy khi muốn thực thi các job đã Approve. Các lệnh sau không tự
chạy khi rebuild app.

```sh
umask 077
TEST_WORKER_DIR=$(mktemp -d "$PWD/runtime/worker/manual-test.XXXXXX")
mkdir "$TEST_WORKER_DIR/repo"
git -C "$TEST_WORKER_DIR/repo" init
printf 'sample data\n' > "$TEST_WORKER_DIR/repo/README.txt"
git -C "$TEST_WORKER_DIR/repo" add README.txt
git -C "$TEST_WORKER_DIR/repo" -c user.name=Test -c user.email=test@example.invalid commit -m 'Test fixture'
openssl rand -hex 32 > "$TEST_WORKER_DIR/token"
TEST_HOST_ID="manual-dev-$(date +%Y%m%d%H%M%S)"
MONASTACK_DB="$PWD/runtime/db/server-office.sqlite3" backend/office-node/target/debug/monastack-office-node host-enroll "$TEST_HOST_ID" le-pha dev-agent < "$TEST_WORKER_DIR/token"
MONASTACK_DB="$PWD/runtime/db/server-office.sqlite3" backend/office-node/target/debug/monastack-office-node host-claims enable
python3 backend/process-node/codex_worker.py --node http://127.0.0.1:47830 --token-file "$TEST_WORKER_DIR/token" --checkout "$TEST_WORKER_DIR/repo" --watch
```

Giữ terminal này mở. Ctrl+C dừng worker. Worker chỉ nhận job Dev/QA theo credential;
muốn test QA phải enroll host khác với qa-agent và checkout riêng.

## 6. Agent hỏi thông tin + tệp + tiếp tục làm

1. Tạo Agent proposal liên kết ticket trong project “Agent update test”. Chọn Atlas.
2. Nhập: “Tạo greeting.txt. Trước khi làm, bắt buộc hỏi tôi muốn lời chào nào.
   Không tự đoán. Khi tôi trả lời, ghi đúng lời chào đó vào file và kiểm tra lại.”
3. Propose → Approve. Worker nhận job rồi trạng thái chuyển waiting_input.
4. Notifications có câu hỏi; Comments trên ticket cũng có câu hỏi.
5. Bấm thông báo, trả lời “Xin chào NVIAI”, đính kèm file text nhỏ nếu muốn, Send.
6. Job quay về approved_waiting rồi được worker nhận lại, với câu trả lời/tệp đính kèm.
7. Thử file >256 KiB: UI phải báo quá giới hạn; tối đa 4 file cho một câu trả lời.
8. Đóng/mở app trong lúc chờ: câu hỏi vẫn còn. User khác không được trả lời thay.

Câu hỏi do mô hình tạo nên nội dung có thể khác câu mẫu. Tệp chỉ đính kèm được vào
câu trả lời cho câu hỏi đang chờ, chưa có nút tải tệp từ ticket.

## 7. Kết quả và duyệt

1. Khi worker hoàn thành, job thành host_reported và có thông báo/comment kết quả.
2. Mở Agent proposals, xem report summary.
3. Kiểm tra greeting.txt trong checkout của worker.
4. Accept result: job completed, ticket Done. Reject result: job rejected, ticket
   không tự Done. Muốn thử cả hai, tạo hai job riêng.
5. Cancel một job đang chạy: worker phải dừng sau lần kiểm tra quyền tiếp theo.

Accept là chấp nhận kết quả, không tự commit/push/merge file vào repository khác.
Report không thay thế việc đọc code/chạy kiểm thử. Timeout mặc định worker là 600s.

## 8. Voice

1. Admin chọn kênh Voice. Đảm bảo live worker và LiveKit đang chạy (local_office status).
2. Đứng ở Lobby/Dev/Product/Sales/Support, bật loa; mic chỉ bật khi muốn trả lời.
3. Tạo câu hỏi như mục 6 trong ticket thuộc project Workspace.
4. Khi câu hỏi xuất hiện, agent trực trong phòng nhắc và có thể đọc câu hỏi công khai.
5. Bật mic, nói câu trả lời rõ ràng, một người nói tại một thời điểm.
6. Kiểm tra câu trả lời đã thành comment và worker tiếp tục.
7. Với ticket riêng tư, chỉ có lời nhắc chung; mở Notifications để đọc/trả lời.
8. Khi voice không hoạt động, thông báo vẫn tồn tại để dùng text.

Chưa test được trong bản này: agent được giao việc đi bộ tới user, voice riêng cho
nội dung riêng tư, duyệt kết quả bằng voice. Duyệt dùng Accept/Reject trong app.

## 9. Kết thúc test worker

Trong terminal chạy worker, Ctrl+C, rồi thu hồi host vừa tạo:

```sh
MONASTACK_DB="$PWD/runtime/db/server-office.sqlite3" backend/office-node/target/debug/monastack-office-node host-revoke "$TEST_HOST_ID"
```

Nếu chỉ có host test và muốn tắt toàn bộ host claims:

```sh
MONASTACK_DB="$PWD/runtime/db/server-office.sqlite3" backend/office-node/target/debug/monastack-office-node host-claims disable
```

Không tắt toàn bộ nếu người khác đang dùng host khác. Giữ checkout để xem kết quả.
Job hết lease do crash chưa tự retry; không coi trạng thái đang chạy là bằng chứng worker còn sống.

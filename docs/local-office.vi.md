# Chạy server + node client + app trên cùng máy

Cấu hình đã được thiết lập tại workspace hiện tại. Các dịch vụ chạy trong session Zellij `monastack-matrix-server` để xem log trực tiếp. Xem [Matrix chat operations](matrix-chat-operations.md).

| Thành phần | Bind | App/tiến trình local kết nối qua |
| --- | --- | --- |
| Node server (identity master) | `0.0.0.0:47830` | `http://127.0.0.1:47830` |
| Realtime server | `0.0.0.0:47831` | `http://127.0.0.1:47831` |
| Node client (member đã join master) | `0.0.0.0:47840` | `http://127.0.0.1:47840` |
| LiveKit server | `0.0.0.0:7880` (signal), `7881/TCP`, `7882/UDP` | `ws://127.0.0.1:7880` |
| Matrix client gateway | `0.0.0.0:8008` | `http://127.0.0.1:8008` |
| Synapse upstream/admin | `127.0.0.1:8009` | backend only |
| Postgres Matrix | Không publish port | Synapse only |
| App macOS | Không có cổng server riêng | Node client `127.0.0.1:47840` |

`MONASTACK_BIND_HOST=0.0.0.0` điều khiển địa chỉ lắng nghe của API và realtime; mặc định khi không đặt vẫn là `127.0.0.1`. **Bắt buộc:** server phải khởi động với IP LAN của chính nó (`MONASTACK_SERVER_HOST=<IP-LAN-server>` hoặc `MONASTACK_MATRIX_PUBLIC_URL=http://<IP-LAN-server>:8008`). Nếu dùng 127.0.0.1, máy khác sẽ thấy "Chat could not connect". Server hiện quảng bá IP LAN theo `runtime/server-address.json` cho realtime và media; xem [script client LAN](start-client-lan.vi.md). Master/member ở cùng máy dùng loopback để trao đổi tài khoản. App có thể kết nối server LAN bằng `MONASTACK_NODE_HOST`; script local vẫn dùng node client trên máy này.

Chạy từ repository root:

```sh
python3 tools/local_office.py status
python3 tools/local_office.py start
python3 tools/local_office.py stop
```

`start` bật Synapse + Postgres + Matrix gateway, một LiveKit dùng chung, node server, node client và app. Node server là nơi duy nhất quản lý phòng media và presence; node client mặc định chuyển tiếp toàn bộ office request về server. `stop` dừng cả app, hai node, Matrix gateway, Synapse, Postgres và LiveKit.

`start` dùng lại tiến trình do script quản lý nếu còn chạy. Nếu cổng bị tiến trình khác chiếm, script dừng thao tác và giữ nguyên tiến trình đó. `stop` giữ database và cấu hình để lần sau tiếp tục dùng. Chỉ chạy hai node, chưa mở app:

```sh
python3 tools/local_office.py start --no-app
```

Nếu sửa source, dừng các tiến trình, build rồi chạy lại:

```sh
python3 tools/local_office.py stop
cargo build --locked --manifest-path backend/office-node/Cargo.toml
cd app
flutter build macos --debug
cd ..
python3 tools/local_office.py start
```

File app: `app/build/macos/Build/Products/Debug/monastack.app`. Script chạy executable bên trong app với `MONASTACK_NODE_PORT=47840`. Nếu tự mở app bằng Finder, biến môi trường này không tự được áp dụng và app sẽ dùng cổng mặc định `47830`.

Dữ liệu:

```text
runtime/.env                       # cấu hình OpenAI dùng chung trên máy này
runtime/db/server-office.sqlite3   # tài khoản master và records của server
runtime/db/client-office.sqlite3   # member directory và records của client
runtime/media/server/livekit.yaml  # config mount của LiveKit server
runtime/media/server/media.key
runtime/matrix/                   # config, secrets, Postgres và media Matrix
# Log: zellij attach monastack-matrix-server
runtime/pids/server.pid
runtime/pids/client.pid
runtime/pids/app.pid
```

App chỉ hiện màn hình đăng nhập trước khi xác thực; đăng xuất quay về màn hình này. Phiên hợp lệ đã lưu có thể được khôi phục tự động.

Đăng nhập app bằng `pha.le`, `hao.hua`, `triet.le` hoặc các [username seed khác](seeded-accounts.md), mật khẩu mặc định `NviaiSeaxOpenAIHackathon`. Không bắt đổi mật khẩu. Script bootstrap đăng nhập `triet.le` để cấp join code khi client mới chưa join; sau khi join sẽ không cần dùng mật khẩu bootstrap lại.

Node client giữ database riêng cho thông tin tham gia master, nhưng chat, task, quyền phòng và các dữ liệu office được đọc/ghi tại server. Ticket realtime lấy từ server, nên mọi client dùng cùng presence `47831` và LiveKit `7880`. Node client không mở realtime `47841` hay LiveKit `7890` nữa. Dữ liệu cũ và config media client cũ được giữ trên đĩa; không tự trộn các record cũ vào server. Hai database hiện tại đã được backup trong `runtime/backups/` trước khi chuyển cấu hình.

OpenAI key được đọc từ `runtime/.env` bởi cả hai node. LiveKit được khởi động tự động bởi script này. Sau đăng nhập, nút mic/camera luôn hiện ở cột bên phải, dùng ngay tại Lobby. Bấm nút để tự kết nối media và bật thiết bị; không cần chọn phòng khác hay bấm Join voice. Mic/camera chỉ thu khi người dùng bật, và macOS có thể yêu cầu quyền truy cập thiết bị.

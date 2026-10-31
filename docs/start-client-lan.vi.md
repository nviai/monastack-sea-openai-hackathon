# Mở client kết nối server LAN 192.168.224.217

Server hiện tại đã được cấu hình để các app dùng chung API, presence và LiveKit qua IP LAN:

| Dịch vụ | Địa chỉ |
| --- | --- |
| Office API | `http://192.168.224.217:47830` |
| Presence | `http://192.168.224.217:47831` |
| LiveKit signaling | `ws://192.168.224.217:7880` |
| LiveKit RTC | `7881/TCP`, `7882/UDP` trên server |

Trên máy client macOS có source mới, Flutter, Rust/Cargo và Xcode, chạy từ repository root:

```sh
./tools/start-client.sh
```

Script mặc định kết nối `192.168.224.217:47830`, kiểm tra server, build app macOS và mở app với đúng địa chỉ. Không chạy node hoặc LiveKit trên client; không cần API key OpenAI trên client. Đăng nhập bằng tài khoản seed thông thường.

Sau khi đã build phiên bản hỗ trợ LAN này, những lần sau có thể bỏ qua build:

```sh
./tools/start-client.sh --skip-build
```

Các tùy chọn:

```sh
./tools/start-client.sh --host 192.168.224.217 --port 47830
./tools/start-client.sh --check
./tools/start-client.sh --stop
```

`--check` chỉ kiểm tra API, không mở app. `--stop` chỉ dừng app do script LAN quản lý, giữ server chạy. App chạy nền; log nằm tại `runtime/logs/client-192.168.224.217-47830.log`, PID tại `runtime/pids/lan-client.pid`. Session Keychain phân biệt theo host và port để tài khoản của các server khác nhau không bị dùng lẫn.

Máy client phải truy cập được các cổng trong bảng trên. Cấu hình này dành cho cùng LAN; nếu macOS hỏi quyền truy cập mạng/mic/camera, cho phép khi sử dụng tính năng tương ứng. Kiểm tra kết nối hai máy vật lý vẫn cần chạy script trên máy thứ hai.

## Cấu hình server hiện tại

`runtime/server-address.json` chứa `{"host":"192.168.224.217"}`. `tools/local_office.py` dùng địa chỉ này để:

- Trả `MONASTACK_REALTIME_PUBLIC_URL=http://192.168.224.217:47831` cho app.
- Trả `MONASTACK_MEDIA_PUBLIC_URL=ws://192.168.224.217:7880` cho app.
- Cấu hình LiveKit `MONASTACK_MEDIA_NODE_IP=192.168.224.217` cho ICE.

Control API của LiveKit vẫn được node server gọi nội bộ qua `127.0.0.1:7880`; key media không gửi cho client.

Khi IP server thay đổi, cập nhật file trên, dừng rồi chạy lại `tools/local_office.py`, và truyền IP mới cho `start-client.sh --host ...`. Có thể override địa chỉ server bằng biến `MONASTACK_SERVER_HOST` khi chạy local_office.py. Chỉ app sử dụng `MONASTACK_NODE_HOST`; master/member enrollment vẫn giữ cơ chế loopback/SSH hiện có.

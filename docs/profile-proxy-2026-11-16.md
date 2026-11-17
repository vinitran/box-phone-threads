# Proxy bắt buộc khi tạo profile — 16/11/2026

App local **0.1.42 / build 42**, engine **1.5.1 / code 9**, RPC API v1.

Trong Profiles, chọn Tạo profile mới và dán một dòng `host:port:username:password`.
Proxy không cần xác thực dùng `host:port`; mật khẩu có thể chứa dấu hai chấm.
Ô nhập được che, xoá khỏi form sau khi gửi và không lưu credentials vào cấu hình proxy
chung trên Mac. Cấu hình vẫn thuộc từng profile trong vùng root của điện thoại.

Luồng tạo: kiểm tra định dạng → từ chối host:cổng đã có → HTTP CONNECT có xác thực
→ TLS kiểm tra chứng chỉ/hostname → GET `https://api.ipify.org/` → HTTP 200 và IP hợp lệ
→ sao lưu profile hiện tại → tạo Android user → chuẩn bị app → chuyển profile.
Không tạo user nếu bất kỳ bước kiểm tra proxy nào thất bại. Engine kiểm tra lại dưới
khoá thao tác, kể cả khi gọi RPC trực tiếp; SDK không cho tạo thiếu proxy hoặc kế thừa.
Proxy phải dùng `routing=enforced`, `transport=device`, không có exclusions.
Không có đường gọi trực tiếp thay thế khi proxy lỗi. Probe có giới hạn kích thước,
timeout socket và hạn 40 giây cho CONNECT/TLS/HTTP sau khi nối được upstream.

TLS dùng trust store mặc định của hệ thống và endpoint identification HTTPS, theo
[Android SSLParameters](https://developer.android.com/reference/javax/net/ssl/SSLParameters#setEndpointIdentificationAlgorithm(java.lang.String)).
Không thêm CA hoặc tắt kiểm tra chứng chỉ trên điện thoại.

## Kiểm tra

- 55 bài Swift không cần thiết bị: qua, gồm dán proxy, mật khẩu có dấu hai chấm,
  giới hạn thông tin xác thực, định dạng lỗi và thông báo lỗi không lộ mật khẩu
- 7 bài SDK: qua, gồm thiếu proxy bị chặn trước khi gọi ADB và timeout không tự tạo lại
- 13 fixture chạy lớp Java production: qua với Content-Length/chunked/connection-close;
  chặn HTTP 407, CONNECT 200 thiếu TLS, chứng chỉ không tin cậy/sai hostname, HTTP 503,
  HTML/IP sai, body thiếu/quá lớn và framing mâu thuẫn. Credentials chỉ có trong CONNECT
- Workflow xoá profile cũ: qua kiểm tra hồi quy
- App release và engine APK build thành công; chữ ký app hợp lệ, signer engine giữ nguyên
- 9 kiểm tra trên điện thoại thật: chặn thiếu/null/none proxy, host/cổng sai, không ép tuyến,
  CONNECT 200 không có TLS và HTTP 407; gọi HTTPS thành công trả IP qua proxy fixture
- Đối chiếu trước/sau: chỉ Owner User 0, giữ UUID và cấu hình của Owner tại đầu lượt test,
  không thêm user/backup; các luật firewall không đổi (bỏ qua bộ đếm lưu lượng và timestamp
  của iptables-save khi so sánh). App thật hiển thị ô dán và khoá nút tạo khi proxy trống

Không tạo profile thật để thử đường thành công: yêu cầu hiện tại là giữ Owner ban đầu.
Bài HTTPS thành công trên điện thoại dùng proxy CONNECT fixture qua ADB reverse tới Mac,
tunnel tới ipify thật; không lưu proxy fixture vào Owner. Đây là kiểm tra giao thức và TLS,
không phải đo chất lượng hoặc IP của proxy thương mại người dùng cung cấp.

Patch engine/SDK: `rom-profile-proxy-2026-11-16.patch`, áp dụng sau patch lifecycle 1.5.0
trong thư mục `~/Documents/rom`. Test fixture mới nằm trong patch; chạy
`python3 tools/test_https_proxy.py`, `python3 -m unittest tools.test_sdk`.
APK cũ được giữ trong `.build/profile-proxy-qa/manager-before-1.5.1.apk` để hoàn tác.

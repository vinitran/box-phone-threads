# Kiểm tra tích hợp ROM Profiles — 15/11/2026

Bản app local 0.1.39 tích hợp engine API v1 có sẵn trong `~/Documents/rom`.

## Kết quả

- 36 test tự động và một test live trên máy ADB được cho phép đều qua
- Giữ nguyên 7 profile; không tạo lại/xóa Android user đang có
- Chuyển User 15 → User 14 → User 15 qua API engine, có backup trước khi chuyển
- File thử riêng trong data của probe giữ nguyên nội dung khi quay về user cũ
- Import 3 ảnh mới ở từng user, kiểm tra thứ tự `app_store.png` ở giữa
- Album User 15 không xuất hiện trong MediaStore User 14
- Xóa batch User 15 từ User 14 bị từ chối; xóa ảnh User 14 không làm mất ảnh User 15
- Helper Java đọc UI được ở user phụ; user ID không khớp bị chặn trước khi điều khiển
- File/ảnh thử được dọn sau test; máy trở lại User 15
- Không đăng nhập, đổi account, đăng bài hoặc comment thử lên mạng xã hội

## Proxy đang có trên máy thử

User 15 có internet qua proxy, native TCP/DNS thành công; UDP/IPv6 ngoài policy bị chặn.
Wi-Fi ban đầu chưa kết nối; áp lại profile hiện tại qua engine đã nối lại được.

Proxy đã lưu của User 14 trả **HTTP 407** khi thử CONNECT/xác thực trực tiếp qua API.
Hostname vẫn trỏ đúng IPv4 đã lưu; chưa thay username/password hoặc mượn proxy của user khác.
Test live đặt `PHONE_FARM_ROM_QA_EXPECT_BLOCKED_USER=14` để xác nhận probe mạng thất bại
nhưng guard vẫn bảo vệ User 14 và chặn app các user không hoạt động. Kết quả test qua
không có nghĩa proxy này đã được sửa. Cần nhập proxy/thông tin xác thực hợp lệ trước
khi chạy Threads ở User 14.

Máy thử có Gboard, chưa cài Threads/Instagram trong User 15. App kiểm tra package bằng user ID số để tránh lỗi Android 10 trả danh sách trống với `--user current`. Cần cài hai app bằng nút Cài của Phone Farm và đăng nhập một lần trong từng user. Cài APK xong app tự gọi `apps.sync` để cập nhật scope engine.

## Phạm vi đã xác minh

Đã xác minh vòng chuyển dữ liệu/ảnh qua hai user hiện có và khóa theo profile trong app.
Các nhãn Threads chỉ là nhãn người dùng nhập; không xác nhận hai tài khoản Threads đã
đăng nhập. Không phát sinh user mới trên máy thử; request tạo profile/proxy được kiểm tra
qua test transport và giao diện, engine đảm nhiệm việc cấp user/backup thực tế.

Log chi tiết chỉ nằm trong `.build/rom-integration-qa/` (gitignored); không đưa credentials,
backup app data hoặc khóa ký của ROM vào repository.

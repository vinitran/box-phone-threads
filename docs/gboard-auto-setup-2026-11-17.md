# Tự chuẩn bị Gboard theo profile — 17/11/2026

App local **0.1.44 / build 44** tự chuẩn bị bàn phím cho chạy Threads, comment thủ công,
đổi bio/avatar và mỗi profile trong luồng luân phiên:

Bản **0.1.46** bổ sung dismiss màn khóa không bảo mật của user phụ, xử lý layout ngôn ngữ
đã tồn tại, ổn định chọn gợi ý và loại gợi ý chữ đơn khỏi tọa độ phím. Cả User 16 và 17
đã gõ đúng câu tiếng Việt trong composer Threads; xem [kiểm tra chạy đêm](overnight-two-profile-2026-11-17.md).

1. Chốt Android user hiện tại và session UUID; kiểm tra lại trước từng thay đổi.
2. Nếu Gboard chưa có trong user, thử install-existing từ APK đã cài trên máy. Nếu chưa có
   APK thì dùng luồng tải/cache/kiểm tra SHA-256 hiện có, chỉ chuẩn bị gói Gboard.
3. Bật package, bật IME và đặt Gboard mặc định bằng **user ID số cụ thể**. Đọc lại để xác minh.
4. Lần đầu mỗi profile trong phiên app, mở Languages của Gboard, thêm/chọn Tiếng Việt và
   layout Telex; trên bản 17.1.5, layout này mang tên Tiếng Việt (Việt Nam) / QWERTY.
   Không xoá tiếng Anh hoặc sao chép dữ liệu bàn phím/từ điển giữa các profile.
5. Trở về Threads trước khi mở editor. Trước mỗi lần gõ, nhấn giữ phím cách và chọn tiếng
   Việt trong bộ chọn ngôn ngữ, rồi mới đọc lại vị trí phím/context và gõ Telex.

Chỉ thêm ngôn ngữ là chưa đủ: thực nghiệm cho thấy lần đầu vẫn gõ theo tiếng Anh nếu
không chọn lại ngôn ngữ đang dùng. Vì vậy bước chọn tiếng Việt được thực hiện mỗi lượt,
kể cả khi đã chuẩn bị Gboard ở đầu phiên. Profile khác có trạng thái cấu hình riêng.

Người dùng vẫn phải cài/đăng nhập Threads và Instagram. Nút chạy cho phép tự chuẩn bị
nếu chỉ thiếu Gboard; thiếu Threads/Instagram vẫn chặn. Layout/settings khác chưa nhận
diện hoặc màn hình khóa cần người dùng xử lý sẽ báo lỗi trước khi gõ/lưu/post.

API chuẩn để bật/chọn IME được đối chiếu với `adb shell ime help` trên Android 10. Gboard
không cung cấp subtype tiếng Việt có thể chọn chỉ qua IME shell trên máy này; phần cấu
hình ngôn ngữ dùng UI của Gboard, giữ user fence và marker huỷ. Tham khảo mô hình
[InputMethodSubtype của Android](https://developer.android.com/reference/android/view/inputmethod/InputMethodSubtype).

## Kiểm tra

- **72 test Swift qua**, gồm 5 test mới: chuyển AOSP→Gboard chỉ cho user 17, đã đúng thì
  không set thừa, đổi foreground user thì dừng trước mutation, enable lỗi không set tiếp,
  session UUID/user không khớp không sửa bàn phím của user khác
- Trên máy thật `2172e30708057ece`, user 17 ban đầu dùng AOSP LatinIME; Gboard đã cài
  nhưng chưa bật, chỉ có English (US). Đã bật/chọn Gboard và tự cấu hình tiếng Việt
- Cài một editor QA riêng không có quyền mạng, chạy đúng KeyboardReader/KeyboardTyper
  production với Telex keys tạo từ source Swift. Trước bước chọn ngôn ngữ, kết quả là
  `Binhf an mooix ngayf`; sau khi tự chọn tiếng Việt, kết quả đúng `Bình an mỗi ngày`
- Đã gỡ editor QA, xoá DEX/JSON/XML tạm trên điện thoại, giữ user hiện tại 17 và Gboard
  mặc định, mở lại Threads. Không tạo/xoá profile hoặc đăng comment trong QA

Logs/fixture nằm trong `.build/gboard-qa/` (gitignored). Không sửa dữ liệu tài khoản,
proxy hay engine ROM trong thay đổi này.

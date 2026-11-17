# Nhất quán thư viện cấu hình QA — 15/11/2026

Phần này là thư viện JSON trên Mac trong `device-profiles`, tách biệt với Android user/
proxy thật trong cửa sổ **Profiles**. Sửa file QA không đổi hệ thống hay phiên đăng nhập trên điện thoại.

## Bộ sinh v2

- Ghép fingerprint theo `brand/product/device:release/id/incremental:type/tags`, lấy trực tiếp từ các thuộc tính cùng profile
- Build ID và display ID cùng dùng `PFTEST.<token>`; incremental QA là số thập phân 10 chữ số
- Giữ `userdebug/test-keys` để thể hiện mẫu QA, thay vì gọi nó là firmware thương mại
- Model, locale/timezone và incremental được chọn bằng SHA-256 của seed theo từng mục, tái lập giữa các lần chạy
- Android 10/SDK 29 có bốn mẫu metadata: SM-G960N, SM-G960F, Pixel 3a, Pixel 4; model có thể trùng ngẫu nhiên
- OS khác giữ model đã chụp; không đổi release/SDK hoặc tự gán mẫu Android 10 cho OS khác
- UUID profile và ngày tạo là metadata của từng bản ghi; không cố tái tạo UUID/ngày tạo từ seed

`generatorVersion=2` cho phép kiểm tra các quy ước mới mà vẫn đọc được JSON cũ không có trường này.
Bản chụp `captured` giữ nguyên giá trị đo được, kể cả khi các trường trên máy đang không nhất quán.
Không tự sửa bản chụp để che mất kết quả đo.

## Sửa profile cũ

Nút **Đồng bộ thuộc tính QA** giữ UUID, seed, tên, createdAt, model, OS, locale và timezone.
Nó chỉ đồng bộ nhóm build QA. Trước khi ghi, app kiểm tra dữ liệu mới, chép nguyên byte file
cũ vào thư mục `device-profiles/backups/` với quyền 0600, rồi ghi file mới theo cách atomic.
Nếu sao lưu thất bại, file đang dùng không bị ghi đè.

`serial` cấp gốc là mã transport ADB để thư viện gắn đúng máy vật lý. Các profile của cùng máy
phải dùng chung serial này. Từng `profiles[].id` là UUID riêng; thư viện QA không sinh serial
phần cứng. Định danh của engine ROM thật là cấu trúc khác, không được sửa bởi nút này.

## Phân biệt quy ước với yêu cầu Android

Theo [AOSP CDD, Build Parameters](https://source.android.com/docs/compatibility/11/android-11-cdd#3_2_2_build_parameters),
fingerprint phải ghép theo các trường tương ứng. Brand `phonefarm` ghi cứng trong fingerprint
cũ trong khi property brand là `google` là lỗi của bộ sinh.

[AOSP Android 10 Build.java](https://android.googlesource.com/platform/frameworks/base/+/android10-release/core/java/android/os/Build.java)
đọc ID và DISPLAY từ hai property riêng, và cho phép INCREMENTAL là số changelist hoặc git hash.
Vì vậy display ID khác build ID, hoặc incremental dạng hex, không tự nó là lỗi Android.
Việc thống nhất ID/display và dùng incremental số ở đây là quy ước rõ ràng của bộ sinh QA.
Không áp quy ước này để từ chối bản chụp OEM hợp lệ.

Chọn **Lưu hiện trạng** để giữ trường build thực tế. Thư viện QA không chứng minh cấu hình
máy thương mại hay kết quả kiểm tra tính toàn vẹn của ứng dụng.

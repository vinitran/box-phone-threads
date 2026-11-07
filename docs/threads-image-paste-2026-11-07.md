# Thử dán ảnh vào bình luận Threads — 07/11/2026

## Kết quả trên thiết bị thật

Samsung Galaxy S9 (SM_G960F), Android 12L/API 32, Threads 454.0.0.54.79.
Thử trong ô trả lời nhanh và màn hình soạn trả lời đầy đủ, chỉ trên bản nháp.
Không bấm Đăng.

| Phép thử | Clipboard | Kết quả trong Threads |
| --- | --- | --- |
| Một ảnh trong ô trả lời nhanh | Một URI ảnh, MIME `image/png` | Không có ảnh đính kèm, ô nhập vẫn trống |
| Một ảnh trong màn hình soạn đầy đủ | Một URI ảnh, MIME `image/png` | Không có ảnh đính kèm, ô nhập vẫn trống |
| Ba ảnh trong màn hình soạn đầy đủ | Ba URI ảnh, MIME `image/png` | Không có ảnh đính kèm, ô nhập vẫn trống |
| Văn bản đối chứng trong màn hình soạn đầy đủ | `text/plain` | Dán đúng `Phone Farm clipboard test` |

`AccessibilityNodeInfo.ACTION_PASTE` trả `true` ở các lần thử. Vì vậy không
thể dùng giá trị này để kết luận ảnh đã đính kèm. Ảnh chụp và cây Accessibility
sau thao tác không có ảnh trong bản nháp; lần thử ba ảnh có
`attachmentNodes=0`. Android có thông báo Threads đã đọc clipboard, nhưng
không chuyển ảnh thành tệp đính kèm. `EditorInfo.contentMimeTypes` là `null`
ở cả hai ô soạn, không công bố hỗ trợ nhận ảnh từ bàn phím.

## Nguồn ảnh

Dùng các bản cache do Phone Farm đã đưa lên Android, không mở thư viện hay
chọn ảnh cá nhân. Đã đối chiếu SHA-256 với ảnh nguồn trong phần mềm:

- `hoan-xu-01.png`: `5db24d5849f49dfe5c7ad4827d9de6292bd59104659be6b9fc9d374623200fb6`
- `app_store.png`: `716f8c9cb1ea59d1fc3fbbd9e1bf23f4797a52e5e8eac943f6fb4ea87fdc6a5e`
- `hoan-xu-02.png`: `68e7ce4dee0cef1bf679ece2edcc3ab524a7c3d6c7ce3aec7561ff4f09c7d26f`

Clipboard chứa URI `content://media/external/images/media/...` của các ảnh
này; đây là thử khả năng nhận ảnh qua paste, chưa phải luồng truyền ảnh từ
máy Mac vào bộ nhớ riêng không qua MediaStore.

## Dọn phép thử và phạm vi kết luận

Clipboard cũ được giữ trong bộ nhớ tiến trình rồi khôi phục trong `finally`
sau mỗi lần thử; không ghi nội dung clipboard cũ ra log hoặc tệp. Đã xóa
văn bản đối chứng và xác minh lại bằng cây giao diện rằng ô nhập trống,
không có ảnh đính kèm; đóng màn hình soạn đầy đủ. Không đăng bình luận.

Chưa thay luồng gửi ảnh của ứng dụng sang paste vì phép thử không thành
công trên phiên bản Threads và thiết bị này. Kết quả không khẳng định mọi
phiên bản Threads đều có hành vi giống nhau. Luồng hiện tại vẫn lấy ảnh
từ thư mục cấu hình của Phone Farm, đưa sang cache Android, rồi chọn qua
giao diện thư viện của Threads.

Mã thăm dò, log, XML và ảnh chụp nằm tại `.build/paste-image-qa/` (không
đưa vào Git). Tham khảo API nhận nội dung ảnh của Android:
[Receive rich content](https://developer.android.com/develop/ui/views/receive-rich-content).

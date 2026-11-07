# Dùng lại ảnh đã nhập trên Android — 07/11/2026

> Cập nhật sau đó: ảnh bình luận đã chuyển sang [đẩy mới mỗi lượt và dọn sau khi gửi](threads-fresh-images-cleanup-2026-11-07.md). Phần kiểm tra dưới đây ghi nhận cơ chế cache trước thay đổi; cache hiện chỉ còn dùng cho avatar.

App giữ ảnh đã nhập trong thư mục riêng `Pictures/PF-CACHE-…` trên từng điện thoại. Trước mỗi lượt, code băm SHA-256 nội dung ba ảnh được chọn và đối chiếu nội dung trên điện thoại. Ảnh còn nguyên được dùng lại; ảnh chưa có, bị xóa hoặc thay đổi được chuyển thêm. Thông tin thư mục và mã MediaStore được lưu vào SQLite theo serial máy, nên mở lại app vẫn dùng được.

Quy tắc chọn ảnh giữ nguyên: hai ảnh khác nhau ngẫu nhiên và `app_store.png` ở giữa. Code sắp đúng ba ảnh lên đầu thư viện rồi kiểm tra thứ tự trước khi gắn vào bình luận. Ảnh dùng lại không được đưa vào hàng đợi xóa ảnh tạm. Các ảnh tạm của phiên bản cũ tiếp tục được dọn theo lịch cũ.

Kiểm tra trên Galaxy S9 thật, không đăng thêm bình luận trong lượt kiểm tra ảnh:

- Lần đầu nhập ba ảnh.
- Lần hai dùng lại cả ba, giữ nguyên đường dẫn và mã MediaStore.
- Tiến trình mới đọc thông tin từ SQLite và dùng lại cả ba ảnh.
- Xóa riêng một bản ảnh đã nhập: chỉ chuyển lại ảnh bị thiếu, hai ảnh còn lại dùng lại; kiểm tra thứ tự thành công.
- Dùng ảnh có nội dung khác nhưng cùng tên tệp: chỉ nhập ảnh mới đó, giữ hai ảnh còn lại. Nội dung cũ vẫn dùng lại được, không sửa ảnh nguồn trong Downloads hoặc thư mục dữ liệu trên Mac.
- Ảnh dùng lại bị từ chối bởi hàm dọn ảnh tạm và không vào hàng đợi xóa sau bấm Đăng.
- Build release, kiểm tra chữ ký và SQLite `quick_check` thành công.

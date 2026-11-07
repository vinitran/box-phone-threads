# Kiểm tra avatar và bio thật — 07/11/2026

Thiết bị Galaxy S9, tài khoản Threads `tran.vini527`.

- Đã đổi avatar thật bằng `app_store.png` trong bộ ảnh người dùng cung cấp, chọn và lưu trong trình cắt ảnh của Threads.
- Đã gọi AI tạo một câu bio, sau đó cập nhật thật:

> Chia sẻ mẹo mua sắm online, săn sale, xin review và so sánh sản phẩm để chọn món phù hợp.

- Đã mở lại Edit profile và trở về trang hồ sơ, thấy bio mới vẫn được giữ và avatar mới hiển thị.
- Phát hiện Threads dùng nhãn `Profile Picture`; đã bổ sung nhãn này để nút mở avatar hoạt động. Kiểm tra lại helper nhận `avatar_picker_open` trên máy thật, rồi hủy trình chọn ảnh để giữ avatar vừa lưu.
- Tăng thời gian đối chiếu bio sau khi bấm lưu vì giao diện chuyển chậm khiến lần đầu trả `bio_unverified` dù sau đó lưu thành công.
- Thêm nút AI tạo bio trong phần Ảnh đại diện & Bio. Bio tạo ra là bản nháp, bấm Cập nhật bio để lưu.
- Build release và kiểm tra chữ ký thành công. Không thử đổi thêm nội dung hồ sơ sau khi xác nhận kết quả.

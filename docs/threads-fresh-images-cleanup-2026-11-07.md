# Ảnh mới mỗi bình luận và tự dọn — 07/11/2026

## Hành vi mới

- Mỗi lần gửi bình luận (thủ công hoặc tự động) chọn lại hai ảnh nguồn khác nhau và giữ `app_store.png` ở vị trí thứ hai như cấu hình hiện tại.
- Luôn tạo và chuyển đủ ba bản PNG mới với 3–6 chấm một pixel ngẫu nhiên, ngay cả khi chọn lại cùng bộ ảnh nguồn. Mỗi lượt có thư mục `Pictures/PF-<UUID>/` và mã MediaStore riêng, không dùng cache ảnh bình luận.
- Chỉ chuẩn bị ảnh trong `ThreadsComment.send`, sau khi nội dung đã được kiểm tra và tác vụ sắp tìm bài để trả lời; luồng tự động không chuẩn bị trước lượt thả tim nữa.
- Kiểm tra đủ ba ảnh và đúng thứ tự trước khi đính kèm. Nếu chuẩn bị ảnh lỗi hoặc bị hủy trước khi đưa vào bản nháp, dọn riêng thư mục nhập dở của lượt đó.
- Khi nhận `reply_submitted`, lưu lịch dọn bộ ảnh vào SQLite với hạn 20 phút kể từ lúc bấm Đăng. Luồng hiện tại không xác nhận bình luận với server; khoảng đệm này tránh xóa nguồn ngay lúc Threads đang xử lý gửi ảnh, không phải bằng chứng upload đã hoàn tất.
- Bộ dọn nền kiểm tra những máy đang kết nối mỗi lần danh sách thiết bị được làm mới, vì vậy không cần đợi lượt bình luận tiếp theo. Lịch tồn tại qua lần đóng/mở app; nếu điện thoại vắng mặt hoặc thao tác xóa lỗi, giữ mục để thử lại.
- Chỉ xóa thư mục tạm `PF-` cộng đúng 32 ký tự hex và bản ghi MediaStore trong chính thư mục đó. Không xóa cache avatar `PF-CACHE-…`, ảnh nguồn trên Mac hay ảnh đã được đính kèm vào bản nháp chưa gửi.
- Chỉ bỏ mục khỏi hàng đợi sau khi xóa thành công cả thư mục và bản ghi MediaStore. Hàng đợi chống trùng album; chỉ chạy một lượt dọn cho mỗi serial tại một thời điểm.

Ảnh cache bình luận từ các phiên bản trước được giữ nguyên; luồng mới không dùng lại hoặc tự quét xóa những ảnh cũ chưa có lịch dọn.

## Kiểm tra

Trên Galaxy S9 kết nối thật, không đăng thêm bình luận:

- Chuẩn bị cùng bộ ba ảnh nguồn hai lần: hai album khác nhau, sáu MediaStore ID khác nhau, ba checksum ở lượt sau đều khác lượt đầu; thứ tự bộ ba được xác minh trên mỗi lượt.
- Xóa album đầu bằng hàm dọn thật: album sau vẫn có đủ ba tệp với checksum cũ. Batch đánh dấu dùng lại và tên album không đúng định dạng không được nhận làm dữ liệu dùng một lần.
- Đưa album sau vào hàng đợi như một lần bấm Đăng mô phỏng: hạn dọn đúng 1.200 giây; chạy bộ dọn trước hạn vẫn giữ đủ ba ảnh và mục hàng đợi.
- Đặt thời điểm bấm Đăng của riêng batch QA về quá hạn rồi chạy bộ dọn: xóa tệp, bản ghi MediaStore và mục hàng đợi của batch đó.
- SHA-256 của cả ba ảnh nguồn trên Mac giữ nguyên. Dữ liệu cache avatar trong SQLite và danh sách tệp cache trên điện thoại không đổi.
- Build release, `codesign --verify --strict` và `git diff --check` thành công. App chính đã được mở lại bằng bản mới, đang ở màn hình nhập mật khẩu.

Mã và log kiểm tra được giữ trong `.build/fresh-comment-images-qa/` (không đưa vào Git).

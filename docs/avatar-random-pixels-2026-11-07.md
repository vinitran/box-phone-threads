# Avatar ngẫu nhiên và chấm pixel khi chuyển ảnh — 07/11/2026

> Cập nhật sau đó: [mỗi bình luận chuyển mới đủ ba ảnh và tự dọn sau 20 phút](threads-fresh-images-cleanup-2026-11-07.md); phần cache ảnh bình luận dưới đây là hành vi trước thay đổi này. Avatar và cách tạo chấm pixel giữ nguyên.

## Hành vi

- Trong **Ảnh đại diện & Bio**, mặc định lấy ảnh từ `~/Downloads/avatar` (9 ảnh người dùng vừa thêm). Hiển thị thư mục, số ảnh hợp lệ, tên tệp và ảnh xem trước.
- **Chọn ngẫu nhiên** chọn một tệp khác tệp đang xem nếu thư mục có nhiều ảnh. **Chọn thư mục…** lưu thư mục vào SQLite để dùng lần sau; thư mục không có ảnh đọc được bị từ chối.
- **Đổi ảnh đại diện** chuyển đúng ảnh đang xem sang Android, kiểm tra mã MediaStore nằm đầu Recents, mở trình chọn avatar rồi chọn sẵn ảnh đó. Dừng ở khung cắt ảnh để người dùng căn chỉnh và bấm Done/Xong, lưu hồ sơ như luồng cũ.
- Trước mỗi thao tác `adb push` ảnh, tạo bản PNG riêng với 3–6 chấm một pixel, tọa độ ngẫu nhiên không trùng nhau. Với ảnh ít hơn ba pixel, giới hạn số chấm theo số pixel. Bản nguồn không bị sửa; ảnh có EXIF orientation được xoay đúng trong bản chuyển.
- Cả ảnh bình luận lẫn avatar đi qua cùng hàm `pushVariant`. PNG được tạo tạm trên Mac và dọn trong `defer` sau khi chuyển, kể cả khi thao tác lỗi/hủy.
- Cache dùng SHA-256 nguồn để định danh đường dẫn `*-pixels-v1.png`, lưu thêm SHA-256 nội dung đã chuyển trong `uploadedHashes`. Ảnh đúng checksum được dùng lại; ảnh mới, bị thiếu hoặc thay đổi được tạo chấm mới rồi chuyển. Cache cũ đọc được và được bổ sung các bản đã thêm chấm khi cần dùng, không xóa ảnh cũ đang tồn tại.

## Kiểm tra

- Chọn ngẫu nhiên 100 lượt từ 9 ảnh, không chọn lại cùng tệp ngay lượt kế tiếp.
- Tệp hỏng và thư mục mang đuôi ảnh bị loại; chọn thư mục không hợp lệ không ghi đè cấu hình.
- Tạo 20 biến thể từ ảnh PNG kiểm soát: mỗi bản đổi đúng 3–6 pixel, cả 20 checksum khác nhau, kích thước giữ nguyên và ảnh nguồn không đổi. Ảnh 1×1 và ảnh EXIF orientation=6 qua kiểm tra.
- Trên Galaxy S9: nhập bộ ba ảnh, xác minh đúng thứ tự; lần hai dùng lại cùng nội dung và mã ảnh. Xóa riêng một bản đã nhập rồi chạy lại: chỉ bản thiếu được tạo mới với checksum khác, hai bản còn lại được giữ nguyên; ảnh nguồn trên Mac không đổi.
- Trên Galaxy S9: chuyển avatar `anh-meo-cute-1.jpg` thành bản PNG có chấm, đối chiếu checksum Android với cache, nhận `avatar_picker_open`, xác minh MediaStore ID rồi nhận `avatar_ready`. Ảnh mèo đúng xuất hiện trong khung cắt; hủy khung xem trước, không lưu thay đổi hồ sơ trong lượt QA.
- Build release thành công, `codesign --verify --strict` và `git diff --check` qua kiểm tra. Đã mở lại app chính bằng bản mới; app đang ở màn hình nhập mật khẩu.

Mã QA, ảnh chụp và log được giữ trong `.build/avatar-random-qa/` và không đưa vào Git.

# Cấu hình Threads và ba ảnh — 07/11/2026

## Cấu hình đã áp dụng

- Nút **Cấu hình Threads** dùng chung cho các máy, với ba tab Chủ đề, Prompt, 3 ảnh.
- Lưu 29 chủ đề người dùng cung cấp, toàn bộ prompt TXT và thư mục ảnh vào bảng `app_settings`; SQLite nâng từ schema 2 lên 3, giữ dữ liệu thiết bị, proxy và lịch sử phiên.
- Bộ 16 ảnh được đóng gói trong app và sao chép vào thư mục dữ liệu ứng dụng. Bản gốc trong Downloads không bị thay đổi.
- Mỗi bình luận chọn hai ảnh khác nhau ngẫu nhiên và đặt `app_store.png` ở vị trí thứ hai. Thao tác thủ công cũng gửi kèm ba ảnh.
- Theo yêu cầu mới nhất, đầu ra không có emoji hoặc icon. Số viết bằng chữ để gõ Telex. Nội dung prompt được lưu nguyên văn; yêu cầu đầu ra này được áp dụng khi gọi AI.

## Phạm vi gọi AI

AI nhận nội dung các bài đã đọc, chủ đề và prompt đã lưu, rồi trả về bài để bình luận, một bài khác để thả tim và nội dung bình luận. Các bước mở app, về Trang chủ, đợi feed, vuốt, tìm lại bài theo ID, gõ phím, chuyển ảnh, chọn ảnh, kiểm tra và đăng chạy bằng code. Không gọi AI để điều khiển giao diện.

## Kiểm tra trên Galaxy S9 thật

- Sửa chủ đề trong giao diện, lưu, mở lại và thấy đúng dữ liệu vừa sửa. Sau kiểm tra đã khôi phục đủ danh sách 29 chủ đề.
- Đối chiếu SQLite: nội dung prompt khớp file người dùng gửi, thư mục mặc định đủ 16 PNG, `quick_check` trả `ok`.
- Thử 100 bộ ảnh: đúng ba tệp khác nhau, ảnh thứ hai luôn là `app_store.png`.
- Gõ trực tiếp trên Gboard câu `S food và voucher.`: nội dung khớp hoàn toàn.
- Kiểm tra tự động chọn ba ảnh trong thư viện và đếm lại trong màn hình soạn. Đã sửa xử lý thứ tự MediaStore và xử lý ô trả lời chuyển sang màn hình soạn đầy đủ.
- Lượt thật đọc 10/10 bài, thả tim một bài và gõ 403 phím Telex cho bình luận 308 ký tự dưới bài của `ttuchom04`. Lượt này ban đầu dừng ở bước mở thư viện. Sau sửa, giữ nguyên bản nháp đã gõ, gắn đủ ba ảnh rồi đăng thật. Kết quả trả `reply_visible`; cây giao diện thấy bình luận dưới tài khoản `tran.vini527` cùng dãy ảnh. Lịch sử ghi rõ lượt đã khôi phục và xác nhận.
- Trước đăng đã đối chiếu thứ tự ảnh trên màn hình soạn, thấy `app_store.png` ở giữa. Bộ ảnh tạm trên Android được dọn sau khi xác nhận đăng thành công.

Nội dung thật đã đăng:

> Vừa đi dạo vừa tâm sự xong ghé ăn cá viên chiên nghe hợp ghê, mấy món ăn vặt buổi tối đúng là dễ rủ nhau đi lắm. Tiện đặt đồ ăn hay sắm đồ thì tải Hoàn Xu nha, đơn đặt qua app trên sàn S, tíc tóc với S food đều có hoàn, tiền tự chuyển thẳng về stk, không giới hạn, mà vẫn áp được voucher của sàn bình thường.

## Luồng Trang chủ theo yêu cầu cuối

Đã thay bước kéo xuống làm mới bằng **bấm Trang chủ một lần → chờ nội dung ổn định → vuốt lên một lần**. Không lặp lại bước này khi tìm bài hoặc sau khi đăng.

Kiểm tra trên máy thật từ màn hình bài viết trả:

```json
{"actionStatus":"home_ready","homeTaps":1,"upSwipes":1,"pulls":0,"loadingSeen":false,"feedChanged":true,"waitMilliseconds":5626}
```

Build release và kiểm tra chữ ký app thành công.

# Chu kỳ Threads và 10 prompt — 07/11/2026

## Hành vi

- Mỗi lần bấm Threads bắt đầu chu kỳ 10 lần bấm Đăng. Sau mỗi lần Đăng, app chuyển về Trang chủ, làm mới bằng một lần bấm Home và một lần vuốt lên theo luồng đã thống nhất.
- Không tìm bình luận để xác nhận đã xuất hiện. Kết quả và bộ đếm ghi rõ là số lần **bấm Đăng**, không coi đó là số bình luận đã được server xác nhận.
- Sau lần thứ 10, thoát màn hình Threads bằng nút Home của Android, giữ Phone Farm trên Mac chạy. Cách này cho phép ảnh vừa gửi tiếp tục tải trong nền. Nghỉ ngẫu nhiên 20–30 phút rồi mở Threads và chạy chu kỳ mới.
- Nút Dừng hủy thao tác hoặc thời gian nghỉ. Dòng thiết bị hiển thị chu kỳ, lượt 1–10 và thời gian còn lại trong lúc nghỉ.
- Nếu chưa bấm Đăng được, không tăng bộ đếm. Lỗi không thể tiếp tục sẽ dừng chu kỳ; không tự gửi lại một bản nháp chưa rõ trạng thái.
- Mỗi lượt vẫn gõ Telex và đính kèm đúng 3 ảnh, `app_store.png` ở giữa. Sau bấm Đăng không xóa ngay ảnh nguồn trên Android; hàng đợi dọn ảnh lưu trong SQLite, từ lượt sau chỉ dọn ảnh đã qua ít nhất 20 phút.
- AI chỉ chọn bài và soạn bình luận. Mỗi lần soạn chọn độc lập một trong 10 file `prompt-bo-tu-01.txt` đến `prompt-bo-tu-10.txt`. Có thể chọn lặp lại ngẫu nhiên giữa các lượt. Cả nút gợi ý thủ công cũng dùng bộ này. Không dùng emoji/icon theo yêu cầu trước đó.
- Bộ prompt lưu đầy đủ trong SQLite, tự bổ sung khi đọc cấu hình cũ. Không thay chủ đề và thư mục ảnh đã lưu. Tab Prompt cho phép chọn xem/sửa từng bộ hoặc nhập lại đủ 10 TXT.

## Kiểm tra có kiểm soát

- Chạy bộ điều khiển thật với tác vụ lượt gửi và đồng hồ thử: hai chu kỳ, mỗi chu kỳ đúng 10 lượt; chỉ thoát Threads sau lượt thứ 10, nghỉ lần lượt 1.200/1.800 giây và đặt lại bộ đếm ở chu kỳ mới. Đồng hồ thử bỏ qua thời gian chờ, không đăng 20 bình luận để thử bộ đếm.
- Lượt gửi thất bại ở lần thứ tư: chỉ ghi nhận ba lần bấm Đăng, không đóng app để nghỉ như thể đã đủ 10.
- Hủy tác vụ trong lúc nghỉ: dừng ngay, không chạy lượt thứ 11.
- Đối chiếu toàn bộ 10 prompt trong SQLite với 10 file gốc: khớp hoàn toàn.
- 1.000 lần chọn prompt chỉ lấy phần tử thuộc bộ đã lưu và chọn được cả 10 bộ.
- Kiểm tra nội dung HTTP gửi AI bằng URLProtocol: mỗi yêu cầu chỉ chứa đúng một prompt nguyên vẹn, cùng chủ đề đã cấu hình và quy tắc không dùng emoji. Không gửi prompt thử tới dịch vụ thật trong kiểm tra này.
- Build release và kiểm tra chữ ký app thành công.

## Lỗi giao diện phát hiện trong lượt thử

- Tìm bài có thể chọn hướng vuốt không phù hợp sau thao tác thả tim. Đã thêm nhận diện đầu feed và đổi hướng khi đến biên, tránh kéo xuống làm mới lặp tại đầu feed.
- Threads ẩn thanh tab khi cuộn xuống. Khi cần bấm Trang chủ, code hiện lại thanh tab trước khi tìm nút Home.

## Lượt thử thật và giao diện

- Lượt thử một bình luận trên Galaxy S9: đọc 5/5 bài, thả tim 1 bài khác, gõ 315 phím Telex, chọn đủ 3 ảnh, bấm Đăng và chuyển về Trang chủ. Kết quả `submitted=true`, `feedReady=true`; không chạy bước tìm bình luận sau đăng. Thời gian toàn lượt khoảng 174 giây.
- Kiểm tra tiếp trạng thái thanh tab bị ẩn ngay ở đầu feed: nút logo Threads trong header được dùng làm Home khi cần. Kết quả `home_ready`, `homeTaps=1`, `upSwipes=1`, `pulls=0`.
- Kiểm tra trên giao diện Phone Farm bản cuối: bấm Threads thấy `Chu kỳ 1 · Lượt 1/10` và nút Dừng; bấm Dừng trước khi gửi thì chuyển sang `Đã dừng chu kỳ Threads.`. Không để chu kỳ kiểm tra chạy nền sau khi hoàn tất.

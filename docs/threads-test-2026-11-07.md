# Kiểm tra Threads trên điện thoại thật — 07/11/2026

Thiết bị: Samsung Galaxy S9 (SM G960F), Android kết nối USB qua ADB. Thao tác bằng ứng dụng Phone Farm trên macOS. Không dùng giả lập. Các lượt bình luận dưới đây đã đăng thật.

## Các lượt hoàn tất từ nút Threads

| Bắt đầu (giờ Việt Nam) | Số bài đọc | Tim được xác nhận | Bình luận được xác nhận |
| --- | --- | --- | --- |
| 14:17 | 5/5 | 1 | 1 |
| 16:50 | 9/9 | 1 | 1 |
| 16:54 | 9/9 | 1 | 1 |
| 16:59 (bản sửa dấu câu cuối) | 9/9 | 1 | 1 |

Kết quả được lưu trong bảng `runs` của SQLite. Log ứng dụng ghi `liked` và `reply_visible`. Ba lượt sau được đối chiếu thêm bằng cây giao diện Android, thấy tên tài khoản `tran.vini527` cùng bình luận đã đăng:

- Bài bánh tráng: “Nhiều loại với giá mềm nghe hấp dẫn quá, bánh tráng nào được mọi người chọn nhiều nhất vậy.”
- Bài set lẩu: “Một set lẩu gồm những món gì và khẩu phần khoảng bao nhiêu người vậy ạ.”
- Bài trang sức bạc: “Có giấy kiểm định và bộ quà tặng đầy đủ vậy khá yên tâm, bạc đeo có dễ xỉn màu không ạ.”

Mỗi lượt mở Threads, trở về đầu feed, kéo làm mới một lần, chờ nội dung ổn định, đọc ngẫu nhiên 5–10 bài, gọi AI ưu tiên mua sắm, thả tim một bài khác bài được bình luận, gõ Telex rồi đăng. App không tự làm mới sau lỗi hoặc sau khi hoàn tất.

## Lỗi tìm thấy và sửa

- Gboard tự sửa “Ba” thành “Bà” khi bấm cách: chọn đúng từ trên thanh gợi ý trước khi kết thúc từ; tránh chèn hai khoảng trắng nếu Gboard đã thêm cách. Đã gõ và đăng đúng câu “Ba Vì có hoa với biển mây nghe hấp dẫn quá.”
- Gboard đổi “helo,” thành “help,” khi gặp dấu phẩy: mở rộng việc giữ từ đúng sang dấu câu; bỏ riêng dấu cách Gboard tự thêm khi chọn gợi ý trước dấu phẩy hoặc dấu chấm.
- Threads có ô trả lời ngay trong bài và màn hình trả lời riêng: xử lý và xác minh cả hai dạng.
- Bài dài khiến tên tác giả khuất khỏi màn hình trả lời riêng: cuộn lên để xác minh bài gốc rồi tìm lại ô soạn. Bản nháp bài cây trang trí đã được giữ nguyên, đăng thật và xác nhận `reply_visible` sau sửa.
- Logo Threads có loại Accessibility là `ProgressBar`: loại vùng logo khỏi bộ nhận diện đang tải, tránh chờ sai rồi báo timeout.
- Bình luận mới ở dưới ảnh cao: tìm tiếp trong luồng bài đã xác minh; không gửi lại. Lượt thử bài đồng hồ từng báo chưa xác nhận dù đã đăng; đã vuốt kiểm tra thấy nội dung thật và sửa bộ kiểm tra.
- Kết nối AI bị ngắt: thêm một lần thử lại có giới hạn cho lỗi mạng tạm thời. Kiểm tra lỗi mạng có kiểm soát xác nhận phục hồi sau một lần ngắt và dừng sau hai lần thất bại; không lặp thao tác công khai.

## Kiểm tra bổ sung

- Chạy bộ gõ chung của nút Gõ Telex và Threads trên điện thoại; kiểm tra nội dung ở ranh giới từ trước khi đăng.
- Hủy tác vụ gõ sau tám phím: trả `CancellationError`, nội dung dừng ở “Kiểm t”, lần đọc sau không có thêm ký tự. Đã dọn riêng bản nháp thử này bằng đối chiếu đúng nội dung và đúng bài.
- Gõ lại nguyên đoạn “helo, em yêu trường em, với bao bạn thân, và cô giáo đẹp, với bao nhiêu yêu THương”: 99 phím Telex trong khoảng 33,5 giây, nội dung trên điện thoại khớp hoàn toàn, gồm dấu phẩy và chữ hoa giữa từ. Đoạn kiểm tra này không được đăng; đã dọn đúng bản nháp thử sau khi đối chiếu.
- Build release thành công; `codesign --verify --strict` thành công; SQLite `quick_check` trả `ok`.

Các lượt lỗi được giữ lại trong lịch sử phiên để phân biệt với lượt hoàn tất. Một lượt thành công chỉ được tính khi đã thấy bình luận xuất hiện, không chỉ dựa vào thao tác bấm Đăng.

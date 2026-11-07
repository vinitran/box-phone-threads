# Sửa xác minh bài Threads — 07/11/2026

Lỗi được tái hiện trên Galaxy S9 ở bài hỏi tìm tiệm bánh handmade của `djsiwinsbx`.

## Nguyên nhân

Android Accessibility trả phần cuối nội dung ở feed là `=))))) �`, nhưng ở màn hình trích dẫn trả lời lại là `=)))))`. Kiểm tra UTF-16 xác nhận ký tự thừa là U+FFFD. Do mã nhận diện và phép so sánh dùng toàn bộ chuỗi, hai màn hình cho cùng một bài bị coi là khác nội dung.

Trước sửa, mã bài ở feed là `a4LHoQAFDeIqzXHybuOuGw0jNPLt7JfYe2CWv+xJCTg=`, còn ở màn hình trả lời là `XYoyRLz3TKbZoawLxYbAFkIFyP+QxUzdERBNejkWjTU=`.

## Thay đổi

- Loại U+FFFD và khoảng trắng dư ở đầu/cuối khi đọc nội dung bài và ngữ cảnh trả lời.
- Giữ nguyên chữ tiếng Việt và emoji hợp lệ trong bài gốc.
- Vẫn đối chiếu chính xác tác giả và nội dung thực; không bỏ bước kiểm tra đúng bài.
- Chờ ngắn cho phần trích dẫn tải xong trước khi kết luận sai bài.
- Bổ sung log giai đoạn/lý do khi xác minh thất bại để phân biệt thiếu trích dẫn, sai tác giả và khác nội dung.

## Kết quả kiểm tra

- Ba lần liên tiếp mở đúng bài trên máy thật: `reply_ready`, tác giả và mã bài khớp màn hình trả lời.
- Kiểm tra thêm cả ô trả lời ngay trong bài và màn hình trả lời đầy đủ: đều `reply_ready` với cùng mã bài.
- Kiểm tra ký tự xác nhận giữ nguyên `💗` và chữ có dấu; bài khác tác giả hoặc khác nội dung vẫn bị từ chối.
- Các lượt kiểm tra tập trung vào mở và xác minh bài, không nhập hoặc đăng bình luận thử.
- Build release và kiểm tra chữ ký thành công.

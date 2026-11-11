# Prompt cố định và bỏ dấu chấm cuối comment — 09/11/2026

- Dev và Production cùng dùng `ThreadsSettings.replyPrompt` đã lưu. Không chọn ngẫu nhiên từ `replyPrompts`; giữ nguyên dữ liệu bộ prompt cũ để đọc lại cấu hình trước.
- Tab Prompt luôn xem/sửa đúng prompt giới thiệu đang được dùng; có thể nhập một file TXT. Không còn bộ chọn hoặc nút nhập 10 prompt cho Production.
- Comment thường vẫn dùng prompt riêng không quảng bá, không nhận prompt giới thiệu.
- Bổ sung chỉ dẫn AI không kết thúc comment bằng dấu chấm hoặc dấu ba chấm. Chuẩn hóa kết quả AI trong luồng tự động và gợi ý thủ công, và chuẩn hóa lại tại đầu `ThreadsComment.send` trước khi tạo phím Telex hoặc thao tác điện thoại.
- Chỉ bỏ các dấu chấm cuối chuỗi (gồm dấu ba chấm và các dạng dấu chấm Unicode), cùng khoảng trắng thừa ở cuối. Giữ dấu chấm giữa câu và dấu câu khác. Comment chỉ có dấu chấm bị từ chối trước khi dùng ADB. Không áp dụng quy tắc này cho bio hoặc bộ gõ Telex chung.
- Không thêm thao tác đọc/đối chiếu nội dung ô nhập trên điện thoại; bộ gõ vẫn theo luồng hiện tại.

Kiểm tra: 4 bài kiểm tra mới cho hai chế độ có bộ prompt cũ, kết quả AI comment thường, dấu chấm giữa câu và đầu vào chỉ gồm dấu chấm. Tổng `swift test`: 20 bài đạt, không có lỗi. Không đăng bình luận công khai để thử.

Log tại `.build/fixed-prompt-qa/` (không đưa vào Git).

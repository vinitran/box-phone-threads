# Chu kỳ 3 giờ xen kẽ giới thiệu và trao đổi — 08/11/2026

## Hành vi

- Mỗi khung 3 giờ chia thành 5 nhóm thời gian, mỗi nhóm bắt đầu bằng một comment giới thiệu rồi ngẫu nhiên 1–2 comment thông thường. Lịch có 5 lượt giới thiệu và 5–10 lượt thường; từng giờ bắt đầu được chọn lại cho mỗi chu kỳ và thiết bị.
- Thời điểm bắt đầu theo lịch cách nhau ít nhất 8 phút. Giữa các tác vụ bị chậm vẫn giữ ít nhất 3–5 phút kể từ khi lượt trước hoàn tất, không chạy nối đuôi để đuổi lịch. Thời gian đọc bài, AI, gõ và gửi được tính vào 3 giờ.
- Sau mỗi lượt đã bấm Đăng, giữ Threads mở 60 giây rồi đóng. Hết khung 3 giờ nghỉ đủ 4 giờ, kể cả khi các lượt hoàn tất sớm phải chờ hết khung trước khi tính thời gian nghỉ.
- Cả Dev và Production dùng lịch mới. Chế độ chỉ quyết định prompt giới thiệu mặc định hay bộ prompt, không rút ngắn thời gian chu kỳ.
- Giới thiệu dùng prompt và chủ đề đã lưu, gửi ba ảnh mới có chấm pixel và dọn ảnh theo lịch 20 phút hiện có.
- Thông thường dùng prompt độc lập, không chèn prompt quảng bá, không ưu tiên tìm bài để giới thiệu ứng dụng, không đọc/chuyển/đính kèm ảnh. Chặn nội dung có Hoàn Xu, tải app, mã giới thiệu hoặc link; không yêu cầu thư mục ảnh hợp lệ cho lượt thường. Nếu bất ngờ có ảnh trong ô soạn, Android không bấm Đăng lượt thường.
- Kiểm tra hạn trước thao tác công khai, sau AI và gõ, trước gửi và ngay tại nút Đăng trên Android. AI không thử lại vượt quá thời gian còn lại. Nếu mạng hoặc thao tác chậm, không bảo đảm gửi đủ 5 lượt; bỏ phần lịch đã hết giờ, không dồn bù. Lỗi gửi khác vẫn dừng chu kỳ để tránh đăng trùng.
- Bộ đếm tăng sau `reply_submitted` như trước, không phải xác nhận bình luận trên server. Giao diện phân biệt số giới thiệu và số thông thường, hiển thị lượt tiếp theo và thời gian nghỉ.
- Cần giữ app trên Mac mở. Lịch và bộ đếm đang chạy nằm trong bộ nhớ; bấm Chạy lại tạo chu kỳ mới, không phục hồi lịch qua lần đóng app.

## Kiểm tra

`swift test`: kiểm tra 1.000 lịch ngẫu nhiên, hai chu kỳ đầy đủ bằng đồng hồ mô phỏng, thời gian nghỉ, hủy, lượt lỗi, máy ngủ quá khung và tác vụ bị chậm. Kiểm tra AI lượt thường không nhận prompt giới thiệu, từ chối câu quảng bá rồi soạn lại, và lượt giới thiệu vẫn nhận prompt đã cấu hình. Không đăng thêm bình luận công khai để thử lịch dài bảy giờ.

Log build và kiểm tra bổ sung tại `.build/mixed-cycle-qa/` (không đưa vào Git).

Kết quả: 11 bài kiểm tra Swift đạt. Helper Java kiểm tra trực tiếp trên Galaxy S9 xác nhận hạn đã qua bị chặn, hạn còn lại được chấp nhận và thao tác thủ công không có hạn vẫn giữ hành vi cũ; không mở UI hay bấm Đăng trong lượt kiểm tra helper. Build release, đóng gói Android DEX và relay, xác minh chữ ký app thành công.

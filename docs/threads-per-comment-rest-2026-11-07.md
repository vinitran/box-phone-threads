# Nghỉ sau mỗi lần Đăng — 07/11/2026

Theo yêu cầu mới, khoảng nghỉ 20–30 phút được chuyển vào sau từng lần bấm Đăng. Luồng mỗi lượt: bấm Đăng → về Trang chủ/làm mới → thoát màn hình Threads bằng Home của Android → nghỉ ngẫu nhiên 1.200–1.800 giây → mở lại Threads và chuẩn bị feed → lượt tiếp theo.

Bộ đếm vẫn theo chu kỳ 10 lượt. Không thêm một khoảng nghỉ thứ hai ở cuối chu kỳ. Dòng thiết bị hiển thị đúng số lượt đã bấm Đăng và thời gian nghỉ còn lại. Nút Dừng hủy được ngay trong lúc nghỉ.

Kiểm tra với bộ điều khiển thật và đồng hồ kiểm soát, không đăng thêm bình luận chỉ để thử thời gian nghỉ:

- 11 lượt bấm Đăng qua ranh giới chu kỳ: đúng 11 lần thoát Threads và 11 khoảng nghỉ, luân phiên hai biên 20/30 phút.
- Không lượt mới nào bắt đầu trước khi lượt trước đã qua bước đóng app và nghỉ.
- Mỗi lượt đều mở lại Threads và chuẩn bị feed sau khoảng nghỉ.
- Lượt không bấm Đăng được không tăng bộ đếm và dừng.
- Dừng ngay ở khoảng nghỉ sau bình luận đầu tiên: hủy ngay, không bắt đầu bình luận thứ hai.
- Build release và kiểm tra chữ ký thành công.

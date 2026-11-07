# Thử lại AI — 07/11/2026

Khi lỗi mạng tạm thời hoặc HTTP 429/5xx, app thử lại tối đa 5 lần sau lần gọi đầu tiên, tổng cộng tối đa 6 yêu cầu trong một đợt kết nối. Mỗi lần thử lại chờ đúng 30 giây. Timeout mỗi yêu cầu giữ 50 giây.

Trạng thái báo lần thử lại 1/5 đến 5/5. Nút Dừng hủy thời gian chờ và không gửi yêu cầu kế tiếp. Không lặp các thao tác điện thoại trong lúc thử kết nối AI. Lỗi khóa hoặc quyền truy cập không được thử lại.

Kiểm tra với URLProtocol và đồng hồ kiểm soát:

- Ba lỗi mạng rồi thành công: 4 yêu cầu, 3 khoảng chờ 30 giây, trạng thái đúng số lần thử.
- Lỗi mạng liên tục: 6 yêu cầu, đúng 5 khoảng chờ 30 giây, sau đó thông báo đã hết 5 lần thử lại.
- HTTP 503/429 được thử lại, HTTP 401 trả ngay sau một yêu cầu.
- Hủy trong khi đang chờ thực tế: kết thúc ngay bằng CancellationError, không gửi yêu cầu thứ hai.
- Build release và kiểm tra chữ ký app thành công.

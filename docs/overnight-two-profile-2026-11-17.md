# Kiểm tra và chạy đêm hai profile — 17/11/2026

App local **0.1.46 / build 46**, máy `2172e30708057ece`, hai profile được chọn là
**User 16** và **User 17**. Owner không nằm trong cặp chạy này.

## Kiểm tra thật trước khi bật

- Tự chuyển profile bằng luồng có sao lưu và kiểm tra proxy/guard. Một lượt đổi sang
  User 17 được đo mất khoảng **148 giây**, phù hợp với việc hạn chế đổi giữa ca.
- Trên từng user, dùng đúng DEX production để cấu hình/chọn Gboard, mở feed Threads,
  tìm một bài có thể reply, mở ô bình luận và gõ bằng KeyboardTyper ở nhịp 140–260 ms.
- Cả hai user đã gõ đúng toàn bộ câu: `Chúc bạn luôn bình an và vững vàng trên con đường mình đã chọn`.
  Probe riêng xác minh và chỉ xoá đúng bản nháp QA đã gõ. Các lượt QA này không bấm Đăng.
- User 16 còn màn khóa kiểu vuốt sau đổi user dù trạng thái là RUNNING_UNLOCKED.
  Bổ sung bật màn hình và yêu cầu hệ thống dismiss keyguard không bảo mật trước Gboard.
- Gboard có hai màn khác nhau: thêm ngôn ngữ lần đầu có Done; sửa ngôn ngữ đã tồn tại
  lưu ngay và chỉ có Navigate up. Đã hỗ trợ cả hai để chuẩn bị lặp lại không bị timeout.
- Ổn định việc chờ gợi ý sau phím dấu Telex và chọn từ đúng, phát hiện dấu cách mà Gboard
  thêm dù từ đang soạn đã được sửa. Không đối chiếu toàn bộ comment với văn bản AI.
- Sửa đọc vị trí phím khi một gợi ý là chữ đơn như `i`/`I`: ưu tiên phím thật nằm dưới
  thanh gợi ý. Ba trường hợp native regression (gợi ý trước phím, phím trước gợi ý,
  gợi ý I viết hoa) đều giữ đúng tọa độ phím.
- **73 test Swift qua**; chữ ký bundle hợp lệ và giữ cùng signer. Helper mới đã đóng vào DEX.

## Khởi chạy khi Mac đang khóa

Mac tự khóa trong lúc kiểm tra nên GUI không còn điều khiển được. Thêm lối khởi chạy
một lần bằng `PhoneFarm --run-two-profiles SERIAL USER_A USER_B`, mật khẩu app nhận riêng
qua stdin và giải mã bằng cùng EncryptedKey. Thử mật khẩu fixture sai trả exit 1 trước
khi mở bất kỳ runner nào. Không ghi mật khẩu vào argv, environment, source hay cấu hình.

Lối này gọi đúng `DeviceManager.runRotatingThreads(... mode: .restWindows)` như nút
**Chạy 2 profile theo ca nghỉ**. Cặp user được chuyển thành hai UUID đang có, kiểm tra
proxy/guard rồi mới chạy; không có chế độ bỏ qua kiểm tra hoặc tự tạo user. Không cài
lịch khởi động cùng hệ thống. App mở theo cách thường vẫn yêu cầu mật khẩu như trước.

Khởi chạy đã xác thực ở background, giữ màn hình Mac khóa. `caffeinate -is -w <PID>`
giữ máy thức trong vòng đời app. Trạng thái chẩn đoán 0600 tại
`~/Library/Application Support/Phone Farm/automatic-run-status.json` chỉ chứa trạng thái,
serial, user, PID và tiến độ; không chứa password/key/proxy credentials.

## Lượt tự động đầu tiên

Khoảng **02:03 ngày 17/11, giờ Việt Nam**, User 17 hoàn thành lượt tự động đầu tiên:
SQLite ghi run `completed`, đã đọc 7/7 bài, một lượt thích, **Đã bấm Đăng 1 lần** và
comment counter tăng lên 1, đúng UUID của User 17. Runner báo **1/5 giới thiệu · 0 thông thường**
và giữ Threads mở 1 phút theo lịch. Đây là xác nhận của luồng bấm Đăng/counter hiện có,
không phải xác nhận độc lập từ server Threads.

Chạy A=User 17 trước vì đang hoạt động, sau khung 3 giờ sẽ bàn giao sang B=User 16.
Hai profile giữ lịch 5 giới thiệu/3 giờ, sau mỗi giới thiệu có 1–2 reply thông thường,
nghỉ 4 giờ riêng; khoảng nghỉ chung chờ và chuẩn bị sớm theo thời gian đổi đo được.

Chứng cứ private/gitignored: `.build/overnight-qa/{16-result.json,17-result.json,keymap.log,
unit.log,auth-rejection.json,launched-app.json}`; database và status tại Application Support.
Không tạo/xoá profile hoặc sửa proxy/account trong lượt kiểm tra này.

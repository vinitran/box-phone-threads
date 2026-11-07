# Phone Farm cho macOS

Ứng dụng SwiftUI để xem các thiết bị Android mà ADB nhận diện. Mỗi thiết bị sẵn sàng có thể mở một cửa sổ scrcpy riêng để xem màn hình và điều khiển bằng chuột, bàn phím.

## Cài đặt và chạy

Cần macOS 13 trở lên, Swift 5.9 trở lên, JDK 11 trở lên và Android SDK có Platform API 24 trở lên cùng Build Tools để build. Khi chạy app, cần ADB và scrcpy để điều khiển thiết bị. Có thể cài hai công cụ này bằng Homebrew.

```sh
brew install scrcpy
brew install --cask android-platform-tools
```

Từ thư mục dự án, chạy:

```sh
./scripts/build-app.sh
open ".build/Phone Farm.app"
```

App tìm ADB trong `PATH`, các thư mục Homebrew và MacPorts phổ biến, hoặc Android SDK ở `~/Library/Android/sdk`, `ANDROID_HOME` hay `ANDROID_SDK_ROOT`. Có thể chỉ định đường dẫn tuyệt đối bằng biến môi trường `ADB` hoặc `SCRCPY` khi chạy app từ terminal. App chuyển đường dẫn ADB đã chọn cho scrcpy để cả hai dùng cùng một bản ADB.

## Tải bản build từ GitHub

GitHub Actions (`.github/workflows/build-macos.yml`) build app universal cho Apple Silicon và Intel. **Mỗi lần push lên `main`** tạo một phiên bản mới: workflow lấy tag `v*` mới nhất, tăng số cuối (v0.1.0 → v0.1.1 → v0.1.2…), ghi số đó vào app và tạo GitHub Release. Lần đầu dùng phiên bản trong `scripts/Info.plist`. Để lên số lớn hơn, đẩy tag thủ công; các lần push sau tiếp tục tăng từ tag đó:

```sh
git tag v1.0.0
git push origin v1.0.0
```

Pull request chỉ build và để file zip trong mục **Artifacts** của tab **Actions**, không tạo Release. Nếu push liên tiếp khi bản trước đang build, GitHub chỉ giữ lần push mới nhất trong hàng đợi.

Mỗi Release kèm file `PhoneFarm-macOS-v<phiên bản>.zip` và mã SHA-256. Bản CI được ký ad hoc, chưa notarize, nên sau khi giải nén cần bỏ cờ cách ly của macOS trước khi mở lần đầu:

```sh
xattr -dr com.apple.quarantine "Phone Farm.app"
```

**Cập nhật trong app:** sau khi mở khóa, app kiểm tra phiên bản mới trên GitHub lúc khởi động và mỗi 6 giờ. Nút phiên bản nằm cạnh ô tìm kiếm: bấm để kiểm tra lại. Khi có bản mới, nút đổi thành **Cập nhật v…**; bấm và xác nhận thì app tải file zip, đối chiếu SHA-256, kiểm tra chữ ký và phiên bản, đóng app (dừng Threads đang chạy), thay bản cũ rồi tự mở lại. Thư mục chứa app phải cho phép ghi (ví dụ Applications của tài khoản quản trị). Bản v0.1.0 chưa có nút này nên cần tải thủ công một lần.

App vẫn hỏi mật khẩu khi mở và cần cài ADB, scrcpy như hướng dẫn ở trên.

## Sử dụng

1. Bật **USB debugging** trên điện thoại, kết nối USB và chấp nhận yêu cầu cấp quyền trên điện thoại. Thiết bị Wi-Fi sẽ xuất hiện nếu đã kết nối với ADB. [Hướng dẫn kết nối](https://github.com/Genymobile/scrcpy/blob/master/doc/connection.md)
2. Mỗi máy hiển thị thành một thẻ; số cột tự đổi theo độ rộng cửa sổ. Dùng bộ lọc **Tất cả / Đang chạy / Sẵn sàng / Cần chú ý** (kèm số lượng) hoặc ô tìm theo tên, serial khi có nhiều máy. Danh sách tự cập nhật khoảng 3 giây một lần. Có thể bấm **Làm mới** hoặc **⌘R** để cập nhật ngay.
3. Mỗi máy ở trạng thái **Sẵn sàng** tự mở cửa sổ scrcpy, cả lúc mở app lẫn khi cắm thêm máy. Cửa sổ hiển thị model và serial để phân biệt các máy cùng model. Phiên mở từ app tắt âm thanh.
4. Đóng trực tiếp cửa sổ scrcpy để kết thúc phiên. Máy đã đóng không tự mở lại cho đến khi ngắt rồi kết nối lại.

## Threads

Bấm **Chạy Threads** để bắt đầu chu kỳ tự động trên từng điện thoại. Mỗi lượt đọc ngẫu nhiên 5–10 bài gốc, bỏ các khối trả lời thụt vào và có nhãn trả lời trong feed, AI chọn một bài gần các chủ đề đã lưu nhất để bình luận và một bài khác để thả tim. AI chỉ chọn bài và soạn nội dung; mở app, chờ feed, vuốt, tìm đúng bài, thả tim, gõ Telex, chọn ảnh và đăng đều chạy bằng code.

Bấm Đăng xong app tính một lượt gửi, không tìm bình luận để xác nhận trên server. **Sau mỗi lần bấm Đăng**, app trở về Trang chủ và làm mới, giữ Threads mở khoảng **60 giây** rồi tắt hẳn Threads bằng `am force-stop`, rồi nghỉ theo chế độ: **Dev 2 phút**, **Production ngẫu nhiên 20–30 phút**. Hết thời gian nghỉ, app mở lại Threads, chuẩn bị feed và tiếp tục lượt kế tiếp. Bộ đếm vẫn chia theo chu kỳ 10 lần; sau lượt thứ 10 chỉ nghỉ một lần như các lượt khác rồi đặt lại bộ đếm ở chu kỳ mới. Phone Farm phải tiếp tục chạy trên Mac. Khi chu kỳ đang chạy, nút đổi thành **Đóng**; bấm **Đóng** để hủy thao tác hoặc khoảng nghỉ, không chạy lượt tiếp theo. Lỗi ngăn bấm Đăng không được tính thêm và dừng chu kỳ để tránh gửi lại bản nháp chưa rõ trạng thái.


Bấm **Cấu hình Threads** ở đầu cửa sổ để chọn Dev/Production và sửa chủ đề, bộ prompt, thư mục ảnh. Chế độ chạy được lưu vào SQLite và áp dụng khi bắt đầu phiên Threads mới. Cấu hình cũ mặc định Production. Các mục dùng chung cho các điện thoại, lưu trong bảng `app_settings` của SQLite và áp dụng từ lượt tiếp theo. Danh sách mặc định có 29 chủ đề, **10 prompt bộ từ** do người dùng cung cấp và bộ 16 ảnh. Ở Production, mỗi lần nhờ AI soạn bình luận app chọn độc lập một trong 10 prompt. Ở Dev, app luôn dùng prompt mặc định đã lưu từ `prompt-mac-dinh.txt`; tab Prompt hiển thị đúng prompt đang được dùng. Tab Prompt cho phép xem/sửa từng bộ hoặc nhập thay đủ 10 file TXT. Prompt được lưu nguyên văn; yêu cầu không dùng emoji/icon, viết số bằng chữ được áp dụng khi gọi AI.

Mỗi bình luận lấy ngẫu nhiên hai ảnh khác nhau, chèn `app_store.png` ở vị trí thứ hai. App dùng lại ảnh đã nhập trên Android, chỉ chuyển ảnh mới, ảnh thay đổi nội dung hoặc bị xóa. Ảnh được nhận diện bằng SHA-256, thông tin thư mục và mã ảnh lưu trong SQLite theo serial điện thoại nên mở lại Phone Farm vẫn dùng được. Trước khi chọn, code xếp đúng bộ ba ảnh lên đầu thư viện, kiểm tra thứ tự và đủ ba ảnh trong màn hình soạn trước khi bấm Đăng. Nếu thiếu ảnh hoặc không xác minh được bài, app giữ bản nháp và dừng. Ảnh nguồn mặc định được sao chép vào thư mục dữ liệu để không phụ thuộc Downloads. Ảnh dùng lại được giữ trên điện thoại, không đưa vào hàng đợi xóa sau bình luận. Các ảnh tạm từ phiên bản cũ vẫn được dọn theo lịch đã lưu. Cả thao tác thủ công cũng gửi kèm ba ảnh và về Trang chủ sau khi bấm Đăng.

Mỗi lần bấm Đăng thành công (chu kỳ tự động hoặc điều khiển thủ công) được ghi vào bảng `comments` trong SQLite. Thẻ thiết bị hiển thị số bình luận của máy đó từ 0 giờ hôm nay theo giờ Mac, dòng tóm tắt ở đầu cửa sổ hiển thị tổng của tất cả máy.

Dòng thiết bị hiển thị thao tác hiện tại, tiến độ đọc bài, tiến độ gõ Telex, thời gian chạy và kết quả cuối phiên. Bộ gõ chạy liên tục trên điện thoại, chạm từng phím với thời gian giữ và vị trí chạm biến thiên nhẹ, nhịp 60–140 ms, nghỉ theo từ và dấu câu. Khi Gboard đề xuất đổi sang từ khác, app chọn từ đúng trên thanh gợi ý trước khi gõ tiếp. App không đối chiếu nội dung đã gõ với bình luận AI soạn: nếu Gboard đổi chữ, app vẫn gõ tiếp và đăng; trước khi bấm Đăng chỉ kiểm tra ô bình luận có chữ.

Khi lỗi mạng tạm thời hoặc dịch vụ AI đang bận, app thử lại tối đa **5 lần sau lần gọi đầu tiên**, cách nhau đúng **30 giây**. Trạng thái hiển thị số lần thử lại. Mỗi yêu cầu vẫn có timeout 50 giây. Bấm Dừng hủy cả thời gian chờ; lỗi khóa truy cập không được thử lại.

Khóa AI được mã hóa trong file `Resources/ai-key.enc.json` (AES-256-GCM, khóa giải mã sinh từ mật khẩu bằng PBKDF2-SHA256 600.000 vòng) và được đóng gói vào app. Mở app phải nhập mật khẩu; khóa sau khi giải mã chỉ nằm trong bộ nhớ, không ghi ra đĩa. File mã hóa có thể đưa lên git, nhưng ai có file đều có thể thử dò mật khẩu ngoại tuyến, nên hãy dùng mật khẩu dài và khó đoán. Khi phát triển có thể bỏ qua màn hình khóa bằng biến môi trường `PHONE_FARM_AI_KEY`.

Để tạo hoặc đổi khóa và mật khẩu, mở Terminal trong thư mục dự án và chạy lệnh sau, nhập khóa AI (nếu được hỏi) và mật khẩu ở lời nhắc ẩn, rồi build lại app:

```sh
".build/Phone Farm.app/Contents/MacOS/PhoneFarm" --encrypt-threads-key
./scripts/build-app.sh
```

Nếu SQLite còn khóa chưa mã hóa từ bản cũ, lệnh dùng khóa đó rồi xóa khỏi database.

Script build ký app bằng chứng chỉ **Apple Development** nếu có, hoặc chứng chỉ chỉ định bằng biến `PHONE_FARM_SIGN_IDENTITY`, để giữ nguyên danh tính app giữa các lần build.

## Proxy trên Android

Phone Farm lưu thiết bị, proxy gần nhất theo serial, kết quả phiên Threads và dấu vết chống bình luận lặp vào SQLite tại `~/Library/Application Support/Phone Farm/phone-farm.sqlite3`. Bấm **Thông tin** để xem dữ liệu thiết bị và hai mươi phiên Threads gần đây. Thiết bị đã lưu tiếp tục xuất hiện với trạng thái ngoại tuyến khi ngắt kết nối. Khóa AI không lưu trong SQLite.

Bấm **Proxy** khi cần cấu hình. Cửa sổ có một ô nhập `host:port:user:pass` hoặc `host:port` và tự điền lại proxy đã lưu. Bấm **Áp dụng** để kiểm tra kết nối HTTPS và thông tin đăng nhập từ điện thoại, sau đó áp dụng và lưu. Cửa sổ đóng khi thành công, dòng thiết bị hiển thị IP kết nối. SQLite lưu địa chỉ, tài khoản và tham chiếu mật khẩu trong Keychain.

Cầu nối xác thực tiếp tục chạy trên điện thoại khi đóng app trên Mac. Sau khi khởi động lại Android, bấm **Proxy** và **Áp dụng** để tạo lại cầu nối. Dùng **Gỡ proxy** để xóa cấu hình proxy HTTP toàn thiết bị và dừng cầu nối. Một số ứng dụng có thể bỏ qua proxy hệ thống.

## Bàn phím Telex cho Threads

Trên điện thoại, chọn **Gboard tiếng Việt Telex** với bố cục QWERTY dọc, đầy đủ chiều rộng. Để giữ đúng chữ hoa và khoảng trắng, bắt đầu với bàn phím chữ thường và tắt tự viết hoa, tự sửa cùng tính năng chèn dấu chấm khi bấm cách hai lần. Phone Farm đọc vị trí phím qua Android Accessibility rồi chạm từng phím.

Bộ gõ hỗ trợ chữ tiếng Việt, chữ Latin, dấu cách, dấu phẩy, dấu chấm và xuống dòng. Với đoạn nhiều dòng, dùng ô nhập có phím **↵**.

# Phone Farm cho macOS

Ứng dụng SwiftUI để xem các thiết bị Android mà ADB nhận diện. Mỗi thiết bị sẵn sàng có thể mở một cửa sổ scrcpy riêng để xem màn hình và điều khiển bằng chuột, bàn phím.

## Cài đặt và chạy

Cần macOS 13 trở lên, Swift 5.9 trở lên, JDK 11 trở lên và Android SDK có Platform API 24 trở lên cùng Build Tools để build. Khi chạy app, cần ADB và scrcpy để điều khiển thiết bị. Có thể cài hai công cụ này bằng Homebrew.

```sh
brew install scrcpy gnirehtet
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
3. Bấm biểu tượng màn hình trên dòng tên của thẻ máy để mở cửa sổ scrcpy; màn hình chỉ mở khi bạn bấm. Biểu tượng chuyển màu khi đang mở. Cửa sổ hiển thị model và serial để phân biệt các máy cùng model. Phiên mở từ app tắt âm thanh.
4. Bấm lại biểu tượng màn hình hoặc đóng trực tiếp cửa sổ scrcpy để kết thúc phiên.

## Cài Threads và Instagram cho máy mới

APK của Threads và Instagram được lưu trên Cloudflare R2, mỗi app một thư mục (`threads/`, `instagram/`) gồm các file APK (base và split) cùng `manifest.json` ghi phiên bản, Android tối thiểu và SHA-256 từng file. Khi mở khóa app và sau đó mỗi 6 giờ, Phone Farm đọc manifest, tải file còn thiếu hoặc đã đổi về `~/Library/Application Support/Phone Farm/apks/` và kiểm tra SHA-256. Trạng thái hiển thị ở biểu tượng **APK** cạnh nút phiên bản (bấm để kiểm tra lại). Không có mạng thì dùng bản đã tải gần nhất.

Khi một máy kết nối mà thiếu Threads hoặc Instagram, thẻ máy hiện nút **Cài Threads & Instagram**; mục cùng tên cũng có trong menu **⋯**. App đã có bản cùng hoặc mới hơn trên máy được bỏ qua; máy cần Android 9 trở lên. Sau khi cài cần mở app và đăng nhập trên điện thoại.

Để phát hành bản APK mới: kéo APK từ một máy đã cài (`adb shell pm path <package>` rồi `adb pull`), tạo `manifest.json` cùng định dạng với `versionCode` mới và SHA-256 của từng file, rồi tải cả thư mục lên R2.

## Cài APK lên điện thoại

Mở menu **⋯** trên thẻ máy và chọn **Cài APK…**, rồi chọn file trên Mac. Có thể chọn một file `.apk`, nhiều file APK của cùng một app (split APK, ví dụ `base.apk` và các `split_config.*.apk`), hoặc file gói `.apks`/`.xapk`. Phone Farm cài bằng `adb install -r` (hoặc `install-multiple -r`), giữ dữ liệu app nếu máy đã có app. Sau khi cài, thẻ máy hiển thị kết quả và phiên bản Threads trên máy. Nếu máy đang có bản mới hơn hoặc app được ký bằng chữ ký khác, cần gỡ app cũ trước.

## Internet qua cáp USB

Khi một máy kết nối, Phone Farm tự bật **internet qua cáp USB** bằng [gnirehtet](https://github.com/Genymobile/gnirehtet): Mac chạy một relay chung, điện thoại cài app gnirehtet (tự cài nếu thiếu) và bật VPN chuyển toàn bộ lưu lượng qua cáp về Mac rồi ra internet bằng mạng của Mac. Quyền VPN được cấp sẵn bằng `appops`, không cần bấm OK trên điện thoại. Biểu tượng cáp trên dòng tên của thẻ máy hiển thị trạng thái (xanh: đang dùng internet qua USB, cam: lỗi, xám: tắt); bấm để tắt (quay lại Wi-Fi/SIM) hoặc bật lại. Khi thoát Phone Farm, VPN trên các điện thoại được tắt để máy dùng lại Wi-Fi/SIM.

Proxy đã áp dụng vẫn hoạt động: lưu lượng tới proxy cũng đi qua cáp USB. Android tự chỉnh giờ bằng mạng riêng của máy (Wi-Fi/SIM), không qua VPN; máy không có Wi-Fi/SIM cần đặt ngày giờ đúng thủ công, nếu sai ngày các kết nối HTTPS sẽ lỗi chứng chỉ.

## Threads

Bấm **Đổi ảnh đại diện & Bio** trên thẻ thiết bị để đổi hồ sơ tự động, không cần xác nhận: AI tạo một câu bio, Phone Farm chọn ngẫu nhiên một ảnh trong thư mục ảnh đại diện (mặc định là bộ 8 ảnh đóng gói sẵn trong app, chép ra `~/Library/Application Support/Phone Farm/avatars/` ở lần dùng đầu; có thể thêm, xóa ảnh trong thư mục đó), chuyển sang điện thoại, chọn ảnh trong Threads, bấm Done ở khung cắt ảnh, rồi lưu bio và ảnh trong cùng một lần lưu Edit profile và kiểm tra bio trên trang hồ sơ. Thẻ thiết bị hiển thị từng bước; lỗi hiện thông báo. Nút bị khóa khi thiết bị ngoại tuyến, đang chạy chu kỳ tự động hoặc đang cài app.

Muốn tự nhập bio, xem trước hoặc đổi thư mục ảnh, chọn **⋯ → Ảnh đại diện & Bio thủ công…**: nhập bio rồi bấm **Cập nhật bio**; **Chọn ngẫu nhiên** để chọn ảnh khác, **Chọn thư mục…** để đổi nguồn (được lưu cho lần sau); **Đổi ảnh đại diện** chọn sẵn ảnh trong Threads để bạn căn chỉnh, bấm Done/Xong và lưu trên điện thoại.

Bấm **Chạy Threads** để bắt đầu chu kỳ tự động trên từng điện thoại. Mỗi lượt đọc ngẫu nhiên 5–10 bài gốc, bỏ các khối trả lời thụt vào và có nhãn trả lời trong feed, AI chọn một bài gần các chủ đề đã lưu nhất để bình luận và một bài khác để thả tim. AI chỉ chọn bài và soạn nội dung; mở app, chờ feed, vuốt, tìm đúng bài, thả tim, gõ Telex, chọn ảnh và đăng đều chạy bằng code.

Nếu máy chưa có proxy đã lưu, bấm **Chạy Threads** hoặc **Đổi ảnh đại diện & Bio** sẽ hiện cảnh báo: chọn **Vẫn chạy…**, **Gắn proxy…** (mở cửa sổ Proxy) hoặc **Hủy**.

Bấm Đăng xong app tính một lượt gửi, không tìm bình luận để xác nhận trên server. **Sau mỗi lần bấm Đăng**, app trở về Trang chủ và làm mới, giữ Threads mở khoảng **60 giây** rồi tắt hẳn Threads bằng `am force-stop`, rồi nghỉ theo chế độ: **Dev 2 phút**, **Production ngẫu nhiên 20–30 phút**. Hết thời gian nghỉ, app mở lại Threads, chuẩn bị feed và tiếp tục lượt kế tiếp. Mỗi chu kỳ gồm 10 lần bấm Đăng. **Sau bình luận thứ 10**, app tắt hẳn Threads và nghỉ **3 giờ** (cả Dev lẫn Production) rồi mới bắt đầu chu kỳ mới với bộ đếm về 0. Phone Farm phải tiếp tục chạy trên Mac. Khi chu kỳ đang chạy, nút đổi thành **Đóng**; bấm **Đóng** để hủy thao tác hoặc khoảng nghỉ, không chạy lượt tiếp theo. Lỗi ngăn bấm Đăng không được tính thêm và dừng chu kỳ để tránh gửi lại bản nháp chưa rõ trạng thái.


Bấm **Cấu hình Threads** ở đầu cửa sổ để chọn Dev/Production và sửa chủ đề, bộ prompt, thư mục ảnh. Chế độ chạy được lưu vào SQLite và áp dụng khi bắt đầu phiên Threads mới. Cấu hình cũ mặc định Production. Các mục dùng chung cho các điện thoại, lưu trong bảng `app_settings` của SQLite và áp dụng từ lượt tiếp theo. Danh sách mặc định có 29 chủ đề, **10 prompt bộ từ** do người dùng cung cấp và bộ 16 ảnh. Ở Production, mỗi lần nhờ AI soạn bình luận app chọn độc lập một trong 10 prompt. Ở Dev, app luôn dùng prompt mặc định đã lưu từ `prompt-mac-dinh.txt`; tab Prompt hiển thị đúng prompt đang được dùng. Tab Prompt cho phép xem/sửa từng bộ hoặc nhập thay đủ 10 file TXT. Prompt được lưu nguyên văn; yêu cầu không dùng emoji/icon, viết số bằng chữ được áp dụng khi gọi AI.

Mỗi bình luận lấy ngẫu nhiên hai ảnh khác nhau, chèn `app_store.png` ở vị trí thứ hai và **chuyển mới đủ ba ảnh** vào một thư mục riêng trên Android. Kể cả khi trùng ảnh nguồn của lượt trước, mỗi lượt vẫn có ba tệp mới với chấm pixel mới, không dùng lại cache ảnh bình luận. Trước khi chọn, code xếp đúng bộ ba ảnh lên đầu thư viện, kiểm tra thứ tự và đủ ba ảnh trong màn hình soạn trước khi bấm Đăng. Nếu thiếu ảnh hoặc không xác minh được bài, app giữ bản nháp và dừng. Sau khi bấm Đăng, bộ ảnh được đưa vào hàng đợi SQLite để **tự xóa sau ít nhất 20 phút**. Phone Farm dọn nền khi app đang mở và điện thoại kết nối, kể cả khi không chạy chu kỳ mới; nếu mất kết nối hoặc đóng app, lịch dọn được giữ để thử lại lần sau. Chỉ xóa thư mục tạm của lượt đã gửi, giữ ảnh nguồn trên Mac, cache avatar và ảnh của bản nháp chưa gửi. Cả thao tác thủ công cũng gửi kèm ba ảnh mới và về Trang chủ sau khi bấm Đăng.

Mỗi lần chuyển ảnh sang Android, app tạo một bản PNG tạm với **3–6 chấm một pixel ở vị trí ngẫu nhiên**, áp dụng cho cả ảnh bình luận và avatar. Ảnh nguồn được giữ nguyên, chiều xoay được áp dụng vào bản chuyển. Avatar vẫn dùng cache riêng với SHA-256 nguồn và bản đã thêm chấm; cache này không nằm trong hàng đợi dọn ảnh bình luận. Tệp tạm trên Mac được dọn sau khi chuyển.

Mỗi lần bấm Đăng thành công (chu kỳ tự động hoặc điều khiển thủ công) được ghi vào bảng `comments` trong SQLite. Thẻ thiết bị hiển thị số bình luận của máy đó từ 0 giờ hôm nay theo giờ Mac, dòng tóm tắt ở đầu cửa sổ hiển thị tổng của tất cả máy.

Dòng thiết bị hiển thị thao tác hiện tại, tiến độ đọc bài, tiến độ gõ Telex, thời gian chạy và kết quả cuối phiên. Bộ gõ mô phỏng nhịp gõ bằng ngón cái: chờ 0,7–2 giây trước khi gõ, mỗi bình luận có tốc độ riêng, khoảng cách giữa hai phím quanh 140–260 ms theo phân bố lệch như người thật, dài hơn khi hai phím xa nhau, nhanh hơn khi bấm lặp cùng phím (`aa`, `dd`) và ngập ngừng trước phím dấu thanh ở cuối từ. Giữa các từ nghỉ khoảng 0,3 giây, thỉnh thoảng dừng 1–3,5 giây như đang nghĩ; sau dấu phẩy và hết câu nghỉ lâu hơn. Mỗi lần chạm giữ khoảng 85 ms, điểm chạm lệch quanh tâm phím và hơi thấp xuống như ngón cái. Bình luận 150 ký tự mất khoảng 60–90 giây. Khi Gboard đề xuất đổi sang từ khác, app chọn từ đúng trên thanh gợi ý trước khi gõ tiếp. App không đối chiếu nội dung đã gõ với bình luận AI soạn: nếu Gboard đổi chữ, app vẫn gõ tiếp và đăng; trước khi bấm Đăng chỉ kiểm tra ô bình luận có chữ.

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

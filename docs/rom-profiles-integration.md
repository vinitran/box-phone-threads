# Nhiều profile thật trên một điện thoại

Phone Farm tích hợp trực tiếp JSON RPC API v1 của engine trong `~/Documents/rom`.
Không cần Python SDK trong bản app phát hành. Điện thoại phải cài engine ROM Profiles
và cấp root từ trước. Điện thoại thông thường tiếp tục dùng luồng proxy cũ.

## Sử dụng

1. Kết nối máy bằng ADB. App nhận diện package `vn.romprofiles` trước khi chọn cách nối mạng
2. Bấm **Profiles** trên thẻ máy. Danh sách lấy từ điện thoại, gồm Android user ID và profile UUID thật
3. Chọn profile có sẵn → **Chuyển sang profile này**, hoặc **Tạo profile mới…** và dán proxy HTTP riêng dạng `host:port:username:password` (hoặc `host:port` nếu không cần xác thực)
4. Engine tự sao lưu profile hiện tại, giữ user cũ và chuyển sang user đã chọn
5. Đăng nhập Threads một lần trên từng user. Lưu nhãn tài khoản để nhận biết, ví dụ `@ten_tai_khoan`
6. Sau khi kiểm tra mạng qua, cài đủ Gboard/Threads/Instagram bằng nút Cài nếu thiếu, rồi dùng các nút Threads hiện có của Phone Farm. App tự đồng bộ scope engine sau khi cài APK

Một máy chỉ điều khiển một profile tại một thời điểm. Dừng chu kỳ Threads và đóng cửa sổ
điều khiển thủ công trước khi chuyển. Profile không dùng vẫn được giữ trên máy.
Nút **Sao lưu** tạo archive/manifest trong vùng root trên điện thoại; không phải khôi phục
user đã xóa hay chuyển phiên đăng nhập sang thiết bị khác.

## Tạo, xoá và tự đổi profile

Bản source ngày 17/11 thêm mặc định **Hai profile · theo ca nghỉ**: A chạy khung 3 giờ,
B chạy khi A nghỉ 4 giờ; đo thời gian đổi và chuẩn bị sớm cho ca tiếp theo. Khi cả hai còn
nghỉ, máy chờ. Chế độ **Đổi mỗi 5 phút** vẫn chọn được. Owner có proxy riêng cũng
được chọn chạy; vẫn không thể xoá Owner. [Kịch bản và kiểm tra](two-profile-schedule-2026-11-17.md).
Thay đổi được đóng gói trong app local 0.1.43 / build 43 sau khi người dùng yêu cầu cập nhật.

App 0.1.41 bổ sung tên/nhãn khi tạo, xác nhận xoá và chế độ chạy luân phiên.
Từ app 0.1.42 và engine 1.5.1, mỗi profile mới bắt buộc có proxy HTTP riêng, ép tuyến
trên điện thoại. Không kế thừa proxy của profile hiện tại. Engine gọi HTTPS qua proxy,
xác minh chứng chỉ và đọc IP thành công trước khi sao lưu hoặc tạo Android user.
Thiếu proxy, trùng host:cổng, xác thực sai hoặc HTTPS lỗi đều dừng trước khi tạo.
Owner ban đầu được giữ nguyên. Xem [kiểm tra proxy bắt buộc](profile-proxy-2026-11-16.md).
Xoá cần engine 1.5.0; chỉ xoá user không hoạt động, không phải Owner, sau khi tạo archive
thành công. Nhập đúng số user trong hộp xác nhận. Android xoá data và phiên đăng nhập
của user đó; bản sao lưu không đảm bảo phục hồi khoá hoặc phiên đăng nhập sau khi xoá.

Nút **Chạy tự động với đổi profile · 5 phút…** trên thẻ máy, hoặc **Chạy luân phiên…**
trong cửa sổ Profiles, cho chọn ít nhất hai profile có proxy ép tuyến riêng. Luồng dùng
chung bộ chạy Threads hiện tại, chạy lần lượt và quay lại đầu danh sách. Nếu profile
hiện tại nằm trong lựa chọn thì bắt đầu từ profile đó.

Thời gian 5 phút bắt đầu sau khi profile sẵn sàng. Đến hạn sẽ ngắt cả lượt đang đọc/gõ,
không chờ gửi nốt bình luận, đóng helper/Threads, chờ tác vụ thoát rồi mới chuyển.
Thời gian sao lưu, chuyển Android user và kiểm tra proxy không tính vào 5 phút.
Mỗi profile giữ kế hoạch 3 giờ, vị trí lượt, cooldown và thời gian nghỉ 4 giờ trong suốt
phiên chạy luân phiên; quay lại không sinh lại lịch. Lượt bị ngắt hoặc chưa rõ đã gửi
được giữ là đã thử để tránh đăng lặp. Những lượt chỉ có thể chạy khi profile đang hoạt động.

Giữ app mở trên Mac. Bấm **Dừng luân phiên** để dừng; nếu đang chuyển user, app chờ
engine trả kết quả trước khi mở lại các thao tác. Thiếu app, proxy lỗi, user/UUID đổi,
kết quả thao tác không rõ hoặc chưa đóng được worker cũ đều làm luồng dừng và báo lỗi.
Xem [kiểm tra và patch engine](profile-rotation-2026-11-15.md).

## Các điểm tách biệt

- Phiên đăng nhập và data ứng dụng: Android user riêng của engine, không clear data hoặc tạo lại khi chuyển về
- Proxy: lưu theo profile UUID trên điện thoại; dùng `transport=device`, `routing=enforced`, không có exclusions
- App từ chối nhập trùng host:cổng với profile khác; engine cũng chặn trùng khi tạo mới. Kiểm tra CONNECT, TLS và HTTPS trả IP trước khi áp dụng
- Ảnh: `/storage/emulated/<userId>/Pictures/PF-<UUID>`, MediaStore và scan chọn đúng user
- Ảnh đại diện đã import, hàng đợi xóa ảnh và bài đã thử reply: khóa riêng theo serial + profile UUID
- Lịch sử chạy/comment: có `profile_id`, vẫn giữ serial thật để tổng hợp theo điện thoại
- Nhãn Threads lưu trên Mac theo serial + profile UUID, không phải mật khẩu hay bằng chứng đã đăng nhập

App không dùng gnirehtet/USB VPN hoặc file proxy cũ trên máy đã nhận diện ROM Profiles.
Engine sở hữu tuyến mạng và chặn các app của user không hoạt động. Proxy thiếu/hỏng,
firewall chưa đúng, đang đổi user hoặc không xác định kết quả thì thao tác Threads bị khóa.

Các tác vụ tự động giữ cố định profile bắt đầu. Trước mỗi lượt app kiểm tra user hiện tại,
profile UUID và guard. Java helper kiểm tra foreground user trước khi thao tác, từng lần
bấm/gõ, để dừng nếu điện thoại đổi user ngoài app. App kiểm tra trạng thái nền mỗi 15 giây.

## API và thông tin nhạy cảm

Lệnh root cố định: `CLASSPATH=/data/adb/romprofiles/manager.apk /system/bin/app_process / vn.romprofiles.Backend rpc 0`.
JSON đi qua stdin và đóng EOF, không chứa credentials trong shell arguments.
Proxy password nhập bằng SecureField, không ghi vào SQLite/log trên Mac; engine lưu trong
vùng root của điện thoại. App chỉ giải mã các trường trạng thái cần dùng, không in lỗi thô của backend.

Chỉ retry lỗi `BUSY` với số lần hữu hạn. Timeout/mất kết nối/phản hồi không hợp lệ không
tự chạy lại mutation. Nút tạo/chuyển bị khóa đến khi **Làm mới** đối chiếu được trạng thái
và engine nhận được yêu cầu đọc sau khi nhả khóa.

## Giới hạn thực tế

Đây là tách data/user và proxy, không phải nhiều máy vật lý độc lập. APK/phiên bản app,
phần cứng, modem và một số dịch vụ Android vẫn dùng chung. Nhãn tài khoản không thể
ngăn người dùng chủ động đăng nhập cùng tài khoản ở nhiều user. Engine chặn UDP ngoài
DNS và IPv6 theo policy, không cung cấp VPN vận chuyển mọi giao thức.

## Kiểm tra

- `swift test`: test RPC/EOF stdin, retry BUSY, không retry mutation không rõ kết quả,
  không lộ credentials, profile fence và lưu riêng cache/ảnh/reply giữa các profile
- `./scripts/build-app.sh`: build Swift release + Java DEX + app bundle ký mã
- Test live opt-in dùng hai profile có sẵn, tạo ảnh/file kiểm thử có tên UUID và xóa sau đó,
  chuyển về user ban đầu. Không đăng bài, comment hay thay tài khoản

```sh
PHONE_FARM_ROM_QA_SERIAL=<serial> PHONE_FARM_ROM_QA_SWITCH_USER=<userId-khac> \
  swift test --filter ROMProfilesLiveTests
```

Test live cần build app trước để có DEX và dùng ảnh trong Resources. Nó tự sao lưu qua
engine trước mỗi lần chuyển. Không chạy đồng thời với app/automation đang điều khiển cùng máy.

Nếu một profile kiểm thử đã biết có proxy lỗi, thêm
`PHONE_FARM_ROM_QA_EXPECT_BLOCKED_USER=<userId>` để kiểm tra network probe thất bại
nhưng guard vẫn bảo vệ đúng user, thay vì đòi proxy đó có internet. Các kiểm tra chuyển
user, giữ data, tách MediaStore và xóa ảnh vẫn chạy đầy đủ. Không dùng tùy chọn này để
kết luận proxy lỗi đã hoạt động.

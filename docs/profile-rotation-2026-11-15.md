# Tạo/xoá profile và chạy luân phiên — 15/11/2026

## Kết quả

App local **0.1.41 / build 41**, engine **1.5.0 / code 8**, vẫn dùng RPC API v1.

- Profiles → Tạo profile mới: tên tuỳ chọn, nhãn Threads và proxy riêng; giữ nhãn sau tạo
- Profiles → Xoá: bảo vệ Owner/current user, xác nhận bằng số user, buộc UUID và thế hệ Android user khớp, kiểm tra archive trước khi yêu cầu Android xoá
- Chạy tự động với đổi profile: chọn ít nhất hai profile, mỗi profile 300 giây chạy, lần lượt rồi quay vòng
- Luồng thường và luân phiên dùng cùng `ThreadsLoop`/`ThreadsAutomation`; giữ prompt, loại bình luận, ảnh và lịch 3 giờ/nghỉ 4 giờ
- Giữ state theo UUID trong phiên luân phiên, không reset lịch khi quay lại; slot được đánh dấu trước khi bắt đầu để không tự gửi lại lượt bị ngắt/chưa rõ kết quả
- Đồng hồ 5 phút bắt đầu sau chuẩn bị profile; sao lưu/chuyển user/xác minh mạng nằm ngoài thời gian này
- Tới hạn huỷ worker, dừng helper/Threads, chờ worker thoát và force-stop lại thành công rồi mới activate user kế tiếp
- Helper Java nhận deadline và từ chối thao tác khi hết hạn, ngoài fence kiểm tra foreground user đã có
- Nút dừng giữ khoá cho đến khi tác vụ/engine đang chạy đã kết thúc; poll trả chậm từ user cũ bị loại bằng generation của lần chuyển

Chọn profile đã cài Gboard, Threads, Instagram và đã đăng nhập tài khoản riêng. Một lỗi
chuẩn bị/chuyển profile sẽ dừng cả vòng để xử lý, không tự chạy trên profile chưa xác minh.

## Xoá và kết quả chưa xác định

`profile.delete` yêu cầu `userId`, `expectedProfileId`, `confirmDeletion=true`.
Mỗi profile được gắn thêm serial thế hệ do Android UserManager cấp, không phải serial
phần cứng; kiểm tra này ngăn dùng lại metadata cũ khi Android tái sử dụng user ID.
UUID/identity/proxy của các profile có sẵn được giữ nguyên.

Quy trình: kiểm tra target → archive/verify → kiểm tra lại → đánh dấu `deleting` →
`pm remove-user` đúng user → đọc lại danh sách Android user → chuyển metadata của
profile đã xoá vào vùng root riêng `deleted-profiles`. Không có lệnh xoá hàng loạt.
Chỉ scope Vector của user đã xoá được dọn; không xoá module hay scope của user khác.

Nếu lệnh xoá mất phản hồi hoặc Android chưa xoá xong, backend trả `RESULT_UNKNOWN`.
App khoá mutation và yêu cầu Làm mới. `profile.reconcile` chỉ đọc trạng thái và cất metadata
khi user thực sự đã biến mất; không phát lại lệnh xoá. Archive được giữ lại, nhưng không
hứa khôi phục khoá Keystore hoặc phiên đăng nhập sau khi Android user bị xoá.

Lệnh quản lý user và các đường data được đối chiếu với
[AOSP: Test multiple users](https://source.android.com/docs/devices/admin/multi-user-testing).

## Kiểm tra

- 53 test Swift không cần điện thoại qua, gồm 10 test cho rotation/cancellation/state
- Chạy toàn bộ có test live: **54 test, 0 lỗi**, 215.348 giây
- Test live chuyển **15 → 14 → 15**, tạo/dọn fixture ảnh và marker riêng, kiểm tra chặn xoá ảnh chéo user, egress/guard và helper từ chối user sai
- Workflow Java thực chạy qua fixtures: Owner/current/confirmation/UUID, archive lỗi, user đổi trong lúc backup, thế hệ user đổi, lệnh mất phản hồi sau commit, không xoá lặp và reconcile metadata bị trì hoãn
- Trên máy thật, 5 yêu cầu bị từ chối đúng: xoá Owner, xoá current user, UUID sai, chưa xác nhận và tên tạo profile không hợp lệ. Không có yêu cầu xoá hợp lệ gửi cho 7 profile hiện tại
- Sao lưu thực tế cả user đang dùng 15 và user không hoạt động 14 thành công; user hiện tại vẫn là 15
- DEX mới trên máy thật từ chối deadline đã hết và deadline không hợp lệ trước khi đọc/thao tác UI; 6 test Python SDK cũng qua
- UI dùng chính hai SwiftUI view mới với transport/dữ liệu mẫu riêng: tạo và giữ nhãn, Owner/current không thể xoá, nhập sai số user không bật nút xoá, xoá đúng một record mẫu, thiếu hai lựa chọn không bật chạy

Các kiểm tra UI mẫu không truy cập điện thoại hay kho dữ liệu thật. Không đăng nhập, đăng
bài, comment hoặc xoá profile thật trong QA. Trên máy thử, Threads/Instagram chưa được
cài; user 14 vẫn có proxy HTTP 407, các user không proxy không thể chọn chạy. Cần chuẩn bị
ít nhất hai profile có app/tài khoản/proxy hợp lệ trước khi chạy comment thực tế.

## Bản build và patch

App: `.build/Phone Farm.app`. APK engine hiện có trong
`~/Documents/rom/profile-manager/build/rom-profiles.apk`; đã cập nhật tại chỗ bằng cùng
chữ ký, không cài lại toàn bộ engine. Giữ hai module ROM Profiles/Vector và cấu hình
Integrity đã thử trước đó.

Nếu app Mac còn mở từ trước khi build, đóng và mở lại bản 0.1.41 để nạp giao diện mới.
Mỗi lần chuyển vẫn tạo backup trên điện thoại; các archive cũ được giữ, không có cơ chế
tự xoá archive trong luồng luân phiên.

[Patch engine/SDK/workflow test](rom-profile-lifecycle-2026-11-15.patch) áp trên bản 1.4.2,
sau [patch sửa chờ mở khoá](rom-profile-unlock-2026-11-15.patch).
Chứng cứ ở `.build/rotation-qa/` (gitignored): APK cũ, baseline/đối chiếu profile, log
build/test, log RPC chỉ có operation/user/mã lỗi, và harness UI dữ liệu mẫu. Các snapshot
có định danh và archive metadata được lưu 0600; không đưa credentials/backup data/khoá ký
vào repository.

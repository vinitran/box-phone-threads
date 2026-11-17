# Hai profile dùng chung thời gian nghỉ — 17/11/2026

Đóng gói vào app local **0.1.43 / build 43** theo yêu cầu cập nhật sau khi người dùng test.
Không cập nhật engine hay chạy thử bình luận trong lần đóng gói này.

## Kịch bản mặc định

Bấm nút riêng **Chạy 2 profile theo ca nghỉ…** trên thẻ điện thoại hoặc trong cửa sổ
Profiles, chọn đúng hai profile rồi bấm **Chạy 2 profile theo ca nghỉ**. Nút mở thẳng kịch
bản theo ca nghỉ; **Đổi profile mỗi 5 phút…** là nút riêng cho kịch bản cũ. Mặc định chọn
hai profile có proxy hợp lệ, ưu tiên profile đang hoạt động khi danh sách cho phép.
Mỗi profile giữ nguyên lịch: 5 lượt giới thiệu trong khung 3 giờ, mỗi lượt theo sau bởi
ngẫu nhiên 1–2 reply thông thường, giờ gửi ngẫu nhiên; sau khung nghỉ 4 giờ.

Chạy trọn ca A rồi bàn giao cho B khi A bắt đầu nghỉ. Những khoảng chờ ngắn giữa comment
vẫn ở cùng profile. Không đổi mỗi 5 phút trong chế độ này và không cắt một comment chỉ
để đổi user. Deadline khung 3 giờ vẫn được kiểm tra trước thao tác, như luồng một account.
Giữ Threads mở 1 phút sau gửi, đóng app, chờ worker trả về rồi force-stop xác nhận thành
công trước khi chuẩn bị profile khác. Lỗi proxy, app thiếu hoặc đóng worker thất bại dừng
cả luồng; không tự chạy sang tài khoản khác để bỏ qua lỗi.

Ví dụ chuyển/kiểm tra mất 3 phút, bắt đầu A lúc 08:00:

| Khoảng thời gian | Hoạt động |
| --- | --- |
| 08:00–11:00 | A chạy khung 3 giờ |
| 11:00–11:03 | Sao lưu, đổi sang B, kiểm tra proxy/app |
| 11:03–14:03 | B chạy; A vẫn nghỉ từ 11:00 |
| 14:03–khoảng 14:56 | Cả hai nghỉ, giữ nguyên profile B |
| Khoảng 14:56–15:00 | Chuẩn bị A sớm, chờ đủ thời gian nghỉ nếu chuyển xong sớm |
| 15:00–18:00 | A chạy ca kế tiếp |
| 18:00–18:03 | Đổi sang B; B đã nghỉ đủ đến 18:03 |
| 18:03–21:03 | B chạy ca kế tiếp |

Đây là ví dụ, không phải lịch giờ cố định. Ca bắt đầu sau khi chuẩn bị xong; lỗi/tác vụ
chậm có thể làm trễ giờ. Mỗi vòng hai ca nhắm tới 10 lượt giới thiệu và 10–20 reply thông
thường, nếu các lượt hoàn thành thành công. Với hai profile cùng tỷ lệ 3 giờ chạy/4 giờ
nghỉ sẽ có xấp xỉ 1 giờ nghỉ chung mỗi vòng 7 giờ. Không tăng quota để lấp giờ nghỉ chung.

Chỉ khoảng hai lần đổi trong một vòng 7 giờ (A→B và B→A), thay vì liên tục đổi lúc chờ
comment/nghỉ 4 giờ. Vẫn giữ **Đổi mỗi 5 phút** cho ít nhất hai profile khi cần test. Cả hai
chế độ đều chạy bình luận thật khi bấm Chạy; đây không phải chế độ mô phỏng.

## Thời gian chuẩn bị và trạng thái

Ước lượng ban đầu là 3 phút. Đo bằng uptime toàn bộ bước prepare khi đổi user, gồm sao
lưu, chuyển Android user, kiểm tra proxy/guard và app; lấy mức lớn nhất trong phiên cộng
biên 30 giây, tối thiểu 3 phút. Lần chuyển chậm sau có thể vẫn làm trễ ca; phép đo giúp
dự phòng cho các lần tiếp theo. Không bỏ backup/kiểm tra mạng để rút ngắn thời gian.

Khi cả hai đang nghỉ, chọn profile được chạy lại sớm nhất và đợi đến giờ chuẩn bị; không
chuyển qua lại. Chuyển xong sớm vẫn chờ đến khi profile đó hết 4 giờ nghỉ mới chạy Threads.
UI hiển thị thời điểm chuẩn bị kế tiếp và số phút dự phòng. Dừng huỷ được cả thời gian chờ;
nếu RPC đang chuyển user thì vẫn đợi nó kết thúc, không mở worker sau lệnh Dừng.

State/lịch đếm giữ riêng theo UUID trong phiên chạy. Không random lại kế hoạch khi quay
lại trong cùng chu kỳ, không gửi lại lượt không rõ đã gửi. Stop/restart phiên tạo kế hoạch
mới như runner hiện tại; chưa lưu lịch chạy qua lần đóng app hoặc khởi động lại Mac.

Owner được chọn nếu có proxy ép tuyến riêng, không trùng host:cổng, đủ app và đăng nhập
Threads riêng. Quy tắc bảo vệ không xoá Owner không thay đổi.

## Kiểm tra

Các test dùng clock giả và callback, không truy cập tài khoản/điện thoại:

- Bốn ca thật của `ThreadsLoop` cho hai profile (gồm Owner): 20 lượt giới thiệu và 30 lượt
  thường, giữ state đúng account, kế hoạch sinh đúng một lần/chu kỳ
- Một comment giả lập dài 7 phút không bị ngắt ở mốc 5 phút; bàn giao sau grace và close
- Đo chuyển 3 phút/10 phút, chuẩn bị sớm có biên, không chạy trước khi nghỉ đủ 4 giờ
- Chờ nghỉ chung không phát sinh prepare/đổi thừa; Stop trong lúc chờ không mở ca mới
- Stop lúc RPC chuẩn bị đang hoàn tất không mở worker; close thất bại, lỗi worker hoặc
  worker kết thúc bất thường đều không kích hoạt profile tiếp theo
- Lựa chọn sai số lượng, thiếu proxy, trùng UUID bị từ chối trước prepare
- Hồi quy lịch một account, prompt, proxy/profile và runner 5 phút

Lệnh: `swift test --skip ROMProfilesLiveTests`. Không chạy live test để tránh gián đoạn tool.
Kết quả: **63 test, 0 lỗi**, gồm 8 test mới cho bàn giao theo ca nghỉ.

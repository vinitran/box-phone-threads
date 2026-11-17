# Profile thông tin máy và ROM tùy chỉnh cho S9

Ngày khảo sát: 08/11/2026. Mục tiêu: tạo profile kiểm thử, lưu lại và tái sử dụng đúng cấu hình trên thiết bị của chủ sở hữu, không phụ thuộc MiChanger/Magisk.

## Khảo sát ban đầu và phần đã triển khai

- Máy kết nối tự báo `SM-G960N`, SoC `samsungexynos9810`, Android `10`, SDK `29`.
- `ro.boot.bootloader` báo `G960NKSU5FUG4`.
- Fingerprint lại báo `samsung/dream2lteks/dream2lteks:9/PPR1.180610.011/G955NKSU3DSI2:user/release-keys`. Đây là dấu hiệu thuộc tính không đồng nhất; chưa đủ để kết luận tên/nguồn ROM hoặc cơ chế sửa đổi đang có.
- ADB chạy với UID shell `2000`. Không tìm thấy `su` trong PATH hoặc các đường dẫn thông dụng đã kiểm tra. `verifiedbootstate=orange` không tự chứng minh đã có backend áp dụng profile.
- Tại thời điểm khảo sát ban đầu chỉ đọc thông tin. Các thao tác root sau khi người dùng yêu cầu ngày 08/11/2026 được ghi riêng bên dưới.

App macOS hiện có thư viện profile theo serial ADB: chụp thuộc tính hiện tại, tạo cấu hình random kiểm thử, đặt tên, chọn lại, xuất và nhập JSON. Chọn profile chỉ lựa chọn bản ghi, không đánh dấu là đã áp dụng. Không nối tính năng này vào chu kỳ Threads.

Giữ nguyên Android release/SDK khi random. Mẫu model là dữ liệu thử nghiệm, không biến CPU/GPU hay khả năng phần cứng S9 thành một thiết bị khác. Bộ sinh QA v2 ghép fingerprint từ chính các trường brand/product/device/release/build ID/incremental/type/tags. Build ID `PFTEST.*`, `userdebug/test-keys` thể hiện dữ liệu QA; không phải fingerprint firmware được chứng nhận. Không thu thập hay sinh IMEI/serial phần cứng. Seed là UUID nội bộ, không phải Android ID.

Profile cấu hình không phải bản backup tài khoản/dữ liệu ứng dụng. Chọn lại profile không phục hồi token đăng nhập, cookie hay trạng thái phía máy chủ.

## ROM nền có thể nghiên cứu tiếp

Ứng viên: fork mã nguồn /e/OS cho `starlte`.

- [Trang thiết bị /e/OS](https://doc.e.foundation/devices/starlte/) liệt kê SM-G960F, SM-G960F/DS và **SM-G960N**, cùng bản A15 và liên kết build. Trang có cả nhãn community và A15 official; phải kiểm tra artifact/nhánh thực tế trước khi chọn bản cụ thể.
- [Hướng dẫn build](https://doc.e.foundation/os/advanced/build/) liên kết manifest `https://gitlab.e.foundation/e/os/android.git` và Docker builder. Cần filesystem phân biệt hoa/thường, ít nhất khoảng 400 GB trống và 16 GB RAM theo tài liệu.
- Hướng dẫn yêu cầu bản sửa tính năng/nhận diện được phân phối dưới tên fork riêng, không dùng nhận diện hoặc hạ tầng OTA chính thức của /e/OS.
- [Tài liệu lịch sử LineageOS cho starlte](https://blob.lineageos.org/preview/wiki/506566/devices/starlte/) cũng liệt kê G960N, nhưng có cảnh báo ngừng duy trì. Đây là tài liệu lịch sử/preview, không coi là bằng chứng còn bản official được cập nhật.

Chưa tải nguồn đầy đủ hoặc tải/kiểm chứng ROM flashable. Chưa chọn hay pin commit của nhánh build. /e/OS nguyên bản không tự có chức năng random profile này.

## Backend ROM còn phải làm

1. Chọn/pin nhánh và commit có cây thiết bị, kernel và vendor blobs hỗ trợ đúng G960N; build được bản nền trước.
2. Chạy thử trên một máy thử nghiệm, kiểm tra USB/ADB, màn hình, Wi-Fi, camera và recovery. Các ứng dụng phụ thuộc Google cần đánh giá riêng vì môi trường /e/OS khác ROM Samsung gốc.
3. Thiết kế dịch vụ quản lý profile trong ROM, giới hạn quyền gọi, kiểm tra schema/allowlist và lưu cấu hình tại vùng hệ thống riêng. Không nhận lệnh shell tùy ý từ JSON hay mở dịch vụ không xác thực qua mạng.
4. Tích hợp những trường đã thống nhất ở framework; không chỉ ghi `build.prop` rồi coi mọi API đều đổi. Các nguồn Java, native, vendor và thông tin phần cứng có thể khác nhau.
5. Thêm client trên Mac để gửi profile, nhận kết quả, đọc lại từ APK kiểm tra độc lập. Chỉ ghi trạng thái “đã áp dụng” sau khi xác minh. Xử lý reboot, mất cáp, lỗi áp dụng và rollback về cấu hình trước.
6. Tách ID phạm vi ứng dụng, dữ liệu app và kiểm tra tính toàn vẹn khỏi các thuộc tính Build; chưa triển khai sửa các nhóm này.

TWRP là công cụ cài đặt/khôi phục, không phải engine random thông tin. Không cần Magisk không đồng nghĩa không sửa hệ thống hoặc không có thành phần có quyền đặc biệt.

## Điều kiện hiện còn thiếu

Mốc 400 GB dành cho **tự build toàn bộ mã nguồn Android**, không phải kích thước file ROM hay yêu cầu để root. Mac có Docker chạy Linux aarch64 nhưng filesystem hiện còn khoảng **189 GiB trống**, thấp hơn yêu cầu của quy trình build toàn bộ trong tài liệu. Nếu đi tiếp theo quy trình này cần ổ/volume phù hợp đủ dung lượng hoặc máy build khác, và xác minh kiến trúc Docker image/toolchain.

Không bắt buộc phải tự build toàn bộ Android để đạt mọi phần của mục tiêu. Có thể đánh giá hai hướng ít dung lượng hơn: chỉnh sửa một ROM/image có sẵn tương thích, hoặc root ROM hiện tại rồi phát triển backend có quyền phù hợp. Chưa kết luận ROM hiện tại hỗ trợ phương pháp nào; không tự chuyển sang root vì lựa chọn trước đó của người dùng là không Magisk.

[Hướng dẫn Magisk cho Samsung](https://topjohnwu.github.io/Magisk/install.html#samsung-devices) yêu cầu kiểm tra OEM Lock/KnoxGuard, dùng firmware đúng máy để patch; cảnh báo cài lần đầu yêu cầu xóa dữ liệu và đánh dấu Knox không thể đảo ngược. Không flash image đã patch sẵn cho máy khác.

Chưa có ROM hoàn chỉnh, backend áp dụng hoặc kết quả kiểm thử trên ROM đó. Không thể đánh giá việc flash trước khi chuẩn bị được artifact và phương án quay về. Mở khóa/format/flash cần bước riêng sau khi người dùng xem bản ROM cụ thể, biết dữ liệu nào sẽ bị xóa và chuẩn bị sao lưu.

## Kiểm tra phần thư viện profile

`swift test` kiểm tra lưu/đọc/chọn lại giữ nguyên seed và giá trị, tách dữ liệu theo máy, từ chối schema/thiết bị/trường không hợp lệ, giữ nguyên file hỏng, fingerprint QA nhất quán, tái tạo từ seed và sao lưu khi sửa bản cũ. Những test này không chứng minh backend ROM hoạt động.

## Thao tác root ngày 08/11/2026 — chưa thành công

Người dùng chuyển sang hướng root và yêu cầu thực hiện. Máy có TWRP `3.7.0_9-0` hoạt động; ADB trong recovery chạy UID 0. Knox trước thao tác báo `1`. `/data` truy cập được trong TWRP, chưa có môi trường Magisk hoạt động trong Android.

Backup và log được giữ tại `~/Library/Application Support/Phone Farm/device-maintenance/S9-G960N-20261108/` trên Mac, ngoài repository:

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `boot-before-root.img` | 57,671,680 | `feee00589024c3ed3915ebfce8e8b5c37753f4dc034aefacdb9eb5fbcd247689` |
| `recovery-before-root.img` | 68,149,248 | `343965c8c64d8f298e90b1f6df6fe1c2f66cc69ff3dd9960c3d7d4e7df431d80` |

Hash đã được đối chiếu với toàn bộ phân vùng trước khi ghi. Chỉ ghi phân vùng BOOT; không wipe/format userdata, không ghi RECOVERY/EFS/modem/bootloader.

- Tải Magisk `v31.1` từ GitHub chính thức; APK SHA-256 `89cefac0a318afa39fb3880c45c87b036c05bc1ebf02a7a715b7f8d7c26ac6e7`. `apksigner verify` thành công; signer SHA-256 `b4cb83b4dad99f997dbe872f013aa16c14eec41d167021f371f7e1330f273ee6`.
- Boot ban đầu có `.backup/.magisk` nhưng môi trường `/data/adb/magisk` không tồn tại. Không coi đây là root đang hoạt động.
- Lần 1: patch từ boot của chính điện thoại bằng script chính thức, flags giữ cấu hình không mã hóa/verity của boot trước, legacy SAR kernel patch. Image `boot-magisk-v31.1.img`, SHA-256 `522cef146b49e8917be10e451020b8eefd81c03880fe5d50af9d17c30f78a6d2`. Bootloop. Log `last_kmsg` ghi `magiskinit: RootFS Init`, không tìm được `init.rc` và `/init`, sau đó `Kernel panic - not syncing: Attempted to kill init`.
- Đã phục hồi nguyên boot trước, xác minh hash và xác nhận Android boot hoàn tất, ADB trở lại; package Threads và Instagram vẫn hiện diện. Di chuyển thư mục Magisk mới sang tên không hoạt động.
- Lần 2: đối chiếu mã nguồn [init.rs](https://raw.githubusercontent.com/topjohnwu/Magisk/v31.1/native/src/init/init.rs) và [getinfo.cpp](https://raw.githubusercontent.com/topjohnwu/Magisk/v31.1/native/src/init/getinfo.cpp), bổ sung `skip_initramfs` vào header cmdline để chọn legacy SAR. Image `boot-magisk-v31.1-legacy-sar.img`, SHA-256 `3d1059f9f2bf3f0a8858ca957c5e8213a5a15d53d37c5524fd9d00ad38a6b800`. Sau khi ghi và reboot, ADB chưa trở lại; chưa xác minh Android boot hay root. Đã yêu cầu đưa máy về TWRP để phục hồi boot trước lần nữa. Không coi bản này là image đã hoạt động.

Ưu tiên tiếp theo là **phục hồi boot trước và xác nhận Android hoạt động**, sau đó mới nghiên cứu root/backend profile tiếp. Không tự nạp thêm image trong khi máy chưa được phục hồi. Khi nhận lại TWRP phải kiểm tra đúng serial/model/bootloader, kiểm tra hash file gốc và phân vùng hiện tại trước khi phục hồi; file gốc nằm trên Mac, không dựa vào `/tmp` vốn mất sau reboot. File `root-operation.json` trong thư mục backup ghi trạng thái thực tế mới nhất.

### Cập nhật cuối: đã phục hồi Android sau lần thử thứ ba

Lần 3 dùng `RECOVERYMODE=true` trong cấu hình ramdisk của Magisk, image `boot-magisk-v31.1-recoverymode.img`, SHA-256 `5813efb08997b34fed9104bb6c80ce8221581fb88285fbcc647612a942f2f743`. Chưa xác minh được Android/root hoạt động; người dùng thấy màn hình xanh tiếng Hàn, USB nhận Samsung Download Mode. Không coi cả ba image thử là image hoạt động.

Đã chuẩn bị `samloader 2.2.0` và build Heimdall CLI để xử lý Download Mode. Chỉ đọc được PIT; các lần ghi bằng samloader bị lỗi handshake trước giai đoạn ghi. Heimdall resume và USB reset không khôi phục kết nối; sau đó người dùng đã đưa máy vào lại TWRP.

**Đã khôi phục thành công qua TWRP**: ghi nguyên `boot-before-root.img` vào BOOT, đọc lại toàn bộ phân vùng và xác minh SHA-256 `feee00589024c3ed3915ebfce8e8b5c37753f4dc034aefacdb9eb5fbcd247689`. RECOVERY vẫn có SHA-256 `343965c8c64d8f298e90b1f6df6fe1c2f66cc69ff3dd9960c3d7d4e7df431d80`. Đã đổi tên thư mục runtime Magisk do tác vụ này tạo sang `/data/adb/phonefarm-magisk-v31.1-third-attempt-not-active` để không hoạt động.

Sau reboot đã xác minh bằng ADB: `sys.boot_completed=1`, model SM-G960N, Android 10; package Threads và Instagram vẫn hiện diện, không có lệnh `su` trong PATH. Không chạy wipe/format, không ghi RECOVERY/EFS/modem/bootloader. Không kết luận đã kiểm tra toàn bộ dữ liệu đăng nhập ứng dụng.

**Trạng thái hiện tại: máy đã trở lại Android; root chưa thành công; backend áp dụng profile chưa có. Không nạp lại ba image đã thử.** Chỉ nghiên cứu phương án mới khi có đúng nguồn ROM/firmware và kế hoạch đã được kiểm chứng; không tiếp tục thử trên boot đang hoạt động. Thư viện profile trên Mac và tính năng đọc API Android là phần độc lập đã build thành công, 16 test đã qua.

Firmware Samsung KOO được server trả về là `G960NKSU5FVG2/G960NOKR5FVG2/G960NKOU5FVA1/G960NKSU5FVG2`; đã khởi tạo tải vào thư mục maintenance, chưa dùng để flash hay thay ROM. Việc cài ROM chuẩn có thể yêu cầu xóa dữ liệu và là bước khác với phục hồi boot vừa hoàn tất.

# Play Integrity trên máy thử — 15/11/2026

## Kết quả và phạm vi

Máy Samsung SM-G960N, Android 10 / SDK 29, Magisk 31.1 và 7 Android user được giữ lại.
Đo Google Play Integrity trong **user 15**, qua SPIC 1.4.0 lấy từ
[release của tác giả](https://github.com/herzhenr/spic-android/releases/tag/v1.4.0), dùng nonce
và giải mã local. Không dùng máy chủ xác minh của bên thứ ba, không đăng nhập Google.

| Cấu hình đã đo | BASIC | DEVICE | STRONG |
| --- | --- | --- | --- |
| Ban đầu, 3 yêu cầu mới, gồm khởi động lại checker | Không | Không | Không |
| PIF v19, provider fallback, script boot mặc định | Có | Không | Không |
| Thêm metadata S9 lấy từ ODM của chính máy | Có | Không | Không |
| Thêm tuỳ chọn chữ ký ROM testkey | Có | Không | Không |
| Thêm Enforce DenyList chỉ cho checker, khởi động lại checker | Có | Không | Không |
| Chỉ provider fallback, tắt cả hai script boot của PIF, reboot | Có | Không | Không |

Cấu hình cuối đạt BASIC trong 3 yêu cầu mới: 16:02:25, 16:10:41 và 16:11:17 giờ Việt Nam.
Hai yêu cầu cuối chạy sau reboot cuối cùng với engine 1.4.2; timestamp JSON lần lượt
`1794733841146` và `1794733877183`, chỉ có nhãn BASIC. Sau reboot, kiểm tra identity và
mạng của engine đều `passed=true`; đối chiếu 7 profile giữ nguyên UUID, user ID, identity,
proxy, tên, createdAt và originalProperties. Máy để lại ở user 15.

Raw JSON ban đầu có `deviceRecognitionVerdict: []`. Raw JSON sau thay đổi có
`["MEETS_BASIC_INTEGRITY"]`. Các yêu cầu dùng nonce và thời gian mới; không suy ra
thành công từ việc sửa fingerprint hoặc nhìn `getprop`.

Đây chưa phải pass đầy đủ. BASIC có thể được trả cho thiết bị có bootloader mở và
boot chưa xác minh; STRONG trên Android 12 trở xuống đòi hỏi bằng chứng boot từ phần cứng.
Xem [định nghĩa các verdict của Google](https://developer.android.com/google/play/integrity/verdicts).

Checker được sideload: sau thay đổi, app verdict là `UNRECOGNIZED_VERSION`, account
verdict `UNEVALUATED`. Không có kết quả chứng nhận Play Protect hoặc kiểm tra chính thức
trong Play Store: Store dừng ở màn hình chưa đăng nhập. Kết quả trên không xác nhận mọi
ứng dụng hoặc mọi user đều dùng được; user 14 hiện có proxy lỗi HTTP 407 nên không thể
đối chiếu Integrity qua đường mạng của user đó.

## Những gì đo được trên ROM thật

- Model/thiết bị báo SM-G960N / starlteks, Android 10 / SDK 29
- System/vendor fingerprint lại ghi Note FE `gracerltektt:9/...N935KKKU4CSE4`
- ODM fingerprint là S9 Android 10 `samsung/starlteks/starlteks:10/QP1A.190711.020/G960NKSU5FUG4:user/release-keys`, khớp bootloader G960NKSU5FUG4
- Property build báo `user/release-keys`, nhưng `/system/etc/security/otacerts.zip` chứa `testkey.x509.pem`
- Boot thực tế báo `orange`, warranty bit 1; bản vá OS báo 2023-02-05
- Play Store đang dùng 54.1.11; Google Play services 26.44.32; yêu cầu API trả verdict, không phải lỗi thiếu mạng

Probe Keystore riêng, không có quyền INTERNET, tạo khoá EC tạm với challenge ngẫu nhiên rồi
xoá alias trong `finally`. Extension trả về TEE, challenge khớp, `deviceLocked=false`,
`verifiedBootState=2`, OS 100000, patch level 202302. Các giá trị không đổi sau khi cài PIF.
Theo [AOSP attestation](https://source.android.com/docs/security/features/keystore/attestation),
state 2 là Unverified. Probe này chưa pin Google root hoặc kiểm tra thu hồi/chữ ký toàn
chuỗi chứng chỉ, nên chỉ dùng làm phép đo đối chiếu; không thay thế verdict Google.

Google không trả nguyên nhân chi tiết cho DEVICE thất bại, nên không kết luận một property
riêng lẻ là nguyên nhân duy nhất. Hướng khôi phục chứng nhận chính thức gồm ROM gốc có chữ
ký hãng và xử lý root/bootloader theo hướng dẫn hãng; xem
[Google Play Help](https://support.google.com/googleplay/answer/7165974?hl=en).
Không thực hiện hướng đó vì yêu cầu giữ root, 7 profile và dữ liệu.

## Thay đổi giữ lại trên máy

Dùng [osm0sis PlayIntegrityFork v19](https://github.com/osm0sis/PlayIntegrityFork/releases/tag/v19).
ZIP gốc được đối chiếu digest của GitHub release:

```text
83b4d5f32743805c5b5a69361d73b8ab9c095325e24f20711afa1abea837b58f
```

Đã đọc script cài/boot và phần cấu hình Java/native ở tag v19 trước phép thử.
Cấu hình cuối chỉ bật `spoofProvider=1`; `spoofBuild`, `spoofProps`, `spoofSignature`,
`spoofVendingFinger`, `spoofVendingSdk`, `verboseLogs` đều bằng 0.
Không giữ metadata hay chữ ký ROM giả từ các phép thử bổ sung.
Không dùng keybox hoặc khoá attestation của thiết bị khác.

Hai file `post-fs-data.sh` và `service.sh` trong module đã được đổi đuôi thành
`.sh.disabled-for-profile-qa`, để Magisk không chạy phần đổi property toàn máy.
Sau reboot, boot property trở lại `orange`, warranty bit 1 nhưng BASIC vẫn đạt.
Các cờ `skippersistprop`, `skipdelprop` và danh sách thay thế app rỗng cũng được giữ.
Hai module cũ `romprofiles_support`, `zygisk_vector` còn nguyên; DenyList trở lại rỗng,
không Enforce như trước khi thử.

Đây là cấu hình cục bộ đã sửa từ v19. Cài bản cập nhật PIF có thể khôi phục script boot;
cần kiểm tra lại trước khi dùng. Không đưa module hoặc file danh tính vào bản phát hành
Phone Farm để tự cài trên máy khác.

## Sửa lỗi chuyển user được phát hiện trong QA

Bài test đầu thất bại khi engine trả `Timed out: am`. Quan sát thấy tiến trình
`cmd activity start-user -w 15` còn chờ dù `get-started-user-state 15` đã trả
`RUNNING_UNLOCKED`. Hiện tượng lặp lại sau khi đã tắt script boot của PIF, nên không
quy kết riêng cho phần đổi property.

Engine trong `~/Documents/rom` được cập nhật từ 1.4.1/code 6 lên **1.4.2/code 7**:

- Đường kích hoạt profile hiện có gọi `am start-user` không chờ callback `-w`
- Chuyển foreground rồi chờ trực tiếp trạng thái `RUNNING_UNLOCKED`, tối đa 30 giây
- Chỉ sau đó mới đọc/ghi file của app trong user và hoàn tất kích hoạt
- Giữ API v1, UUID, identity, proxy và dữ liệu Android user

[Patch nguồn để review/áp lại](rom-profile-unlock-2026-11-15.patch).
APK mới được build, xác minh chữ ký trùng APK cũ trước `install -r`, rồi thay bản backend
root theo cách atomic. APK cũ được lưu riêng trước khi cập nhật. Không chạy lại script
cài đặt toàn bộ engine hoặc khởi tạo lại profile.

Sau sửa, test live `testExistingProfilesAndMediaSurviveRoundTrip` qua với **0 lỗi,
202.604 giây**. Test kiểm tra 15 → 14 → 15, ảnh mới ở từng user, không đọc/xoá batch ảnh
chéo user, file riêng còn nguyên khi quay lại, egress user 15 như cũ, guard bảo vệ user 14
khi proxy lỗi, và helper UI từ chối user không khớp. Fixture thử được dọn và máy trở về 15.
Không đăng bài, comment hay đổi tài khoản mạng xã hội trong phép thử.

## Sao lưu, chứng cứ và hoàn tác

Archive user 15 trước phép thử: 118380837 byte, `complete=true`, SHA-256 đã đọc và đối chiếu
trên máy. Đây là archive file đang chạy, loại trừ cache và khoá phần cứng, không phải bản
chuyển tài khoản/Keystore sang máy khác. Dữ liệu gốc được giữ tại chỗ trong cả 7 user.

BOOT 57671680 byte được sao lưu riêng với quyền 0600. SHA-256 trước và sau các reboot:

```text
0c25e8dffc052145ea1d09a750324902fbe70b2a13c1b8b43618ba03124578f9
```

Chứng cứ chi tiết chỉ ở `.build/play-integrity-qa/` (gitignored): cấu hình từng lượt thử,
`trial-observations.json`, kết quả Keystore, log build/cài APK, log test live và RPC đã lọc
chỉ còn operation/user/mã lỗi. Không đưa backup app data, credentials, khoá ký hoặc keybox
vào repo.

Probe attestation tự tạo và file staging của phép thử đã được dọn. SPIC được giữ ở user 15
để người dùng có thể đo lại; chưa có account Google nào được thêm trong phép thử.

Để bỏ phép thử Integrity, chỉ tắt module mới và reboot, dùng đúng serial máy:

```sh
adb -s "$SERIAL" shell su -c "'touch /data/adb/modules/playintegrityfix/disable'"
adb -s "$SERIAL" reboot
```

Giữ hai module quản lý profile. Sau reboot dùng engine chọn lại user 15 và kiểm tra guard/
proxy; không dùng lệnh xoá toàn bộ module Magisk. Tắt PIF sẽ mất cải thiện BASIC đã đo.

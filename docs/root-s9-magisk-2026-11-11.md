# Root Galaxy S9 bằng Magisk qua TWRP

Thực hiện thành công ngày 11/11/2026 trên S9 `SM-G960N`, serial `2172e30708057ece`, bootloader `G960NKSU5FUG4`, Android 10, TWRP `3.7.0_9-0`, Magisk `v31.1`. Kết quả: `su -c id` trả `uid=0(root) context=u:r:magisk:s0`, SELinux vẫn Enforcing, dữ liệu và app giữ nguyên.

Quy trình này dùng được cho máy tương tự (S9/S9+ Exynos, Android 10, boot image header v0) **đã mở khóa bootloader và đã có TWRP**. Máy khác đời hoặc Android khác phải đọc lại phần kiểm tra ở bước 4 trước khi nạp.

## Điều kiện trước khi bắt đầu

- Bootloader đã mở, TWRP hoạt động, `adb` trong TWRP chạy UID 0. Quy trình này không gồm mở khóa OEM (xóa dữ liệu) hay cài TWRP qua Download Mode.
- Không có chu kỳ Threads đang chạy trên máy đó. Cả quy trình khởi động lại máy nhiều lần.
- Magisk APK tải từ [GitHub chính thức](https://github.com/topjohnwu/Magisk/releases). Bản đã dùng: `Magisk-v31.1.apk`, SHA-256 `89cefac0a318afa39fb3880c45c87b036c05bc1ebf02a7a715b7f8d7c26ac6e7`, signer SHA-256 `b4cb83b4dad99f997dbe872f013aa16c14eec41d167021f371f7e1330f273ee6` (kiểm tra bằng `apksigner verify --print-certs`).
- **Mỗi máy patch từ boot của chính nó.** Không nạp image của máy khác, kể cả cùng model.

Biến dùng trong các lệnh dưới:

```sh
S=<serial adb>
D="$HOME/Library/Application Support/Phone Farm/device-maintenance/<tên-máy>-<ngày>"
mkdir -p "$D"
```

## Bước 0: Kiểm tra máy không bận

```sh
sqlite3 -readonly "$HOME/Library/Application Support/Phone Farm/phone-farm.sqlite3" \
  "select serial, started_at from runs where state='running'"
adb -s $S shell 'ps -A -o ARGS | grep app_process | grep -v grep'
```

Có dòng nào thuộc serial `$S` thì dừng, chờ chu kỳ kết thúc.

## Bước 1: Sao lưu BOOT và RECOVERY trong TWRP

```sh
adb -s $S reboot recovery
# chờ: adb -s $S get-state  ->  recovery
adb -s $S shell 'id -u; getprop ro.boot.bootloader; getprop ro.boot.serialno; ls -la /dev/block/by-name/BOOT /dev/block/by-name/RECOVERY'
adb -s $S pull /dev/block/by-name/BOOT "$D/boot-before-root.img"
adb -s $S pull /dev/block/by-name/RECOVERY "$D/recovery-before-root.img"
shasum -a 256 "$D"/boot-before-root.img "$D"/recovery-before-root.img
adb -s $S shell 'dd if=/dev/block/by-name/BOOT bs=1048576 2>/dev/null | sha256sum'
```

Hash file trên Mac phải trùng hash đọc trực tiếp từ phân vùng. Ghi hash vào `partition-backups.json` trong `$D`. Xong thì `adb -s $S reboot` về Android.

## Bước 2: Lấy công cụ Magisk từ APK

```sh
mkdir -p "$D/magisk-tools" && cd "$D/magisk-tools"
unzip -o -j ../Magisk-v31.1.apk 'assets/boot_patch.sh' 'assets/util_functions.sh' 'assets/app_functions.sh'
for n in magiskboot magiskinit magisk magiskpolicy busybox init-ld; do
  unzip -o -p ../Magisk-v31.1.apk "lib/arm64-v8a/lib$n.so" > $n
done
unzip -o -p ../Magisk-v31.1.apk lib/armeabi-v7a/libmagisk.so > magisk32
chmod 755 magiskboot magiskinit magisk magisk32 magiskpolicy busybox init-ld
```

Các binary này chạy trên điện thoại, không chạy trên Mac.

## Bước 3: Xóa dấu Magisk cũ và patch, làm trên Android đang chạy (không cần root)

```sh
T=/data/local/tmp/pf-root
adb -s $S shell "rm -rf $T && mkdir -p $T"
adb -s $S push "$D/magisk-tools/." $T/
adb -s $S push "$D/boot-before-root.img" $T/boot.img
adb -s $S shell "cd $T && chmod 755 magiskboot magiskinit magisk magisk32 init-ld busybox magiskpolicy \
  && ./magiskboot unpack boot.img \
  && ./magiskboot cpio ramdisk.cpio test; echo test=\$?"
```

Ý nghĩa `test`: `0` boot gốc, `1` có dấu Magisk, `2` bị công cụ khác sửa (dừng lại).

**Nếu `test=1`, kiểm tra trước khi đi tiếp:**

```sh
adb -s $S shell "cd $T && ./magiskboot cpio ramdisk.cpio 'ls -r .backup'"
```

Nếu `.backup` chỉ có `.magisk` mà **không có** `init`/`init.xz`, đó là dấu Magisk sót lại. Phải xóa nó (bước dưới). Không xóa thì script Magisk sẽ chạy `restore`, xóa trắng ramdisk và máy bootloop (xem phần "Lỗi đã gặp").

```sh
adb -s $S shell "cd $T && ./magiskboot cpio ramdisk.cpio 'rm -r .backup' \
  && ./magiskboot cpio ramdisk.cpio test; echo test_after=\$? \
  && ./magiskboot cpio ramdisk.cpio ls \
  && ./magiskboot repack boot.img clean-boot.img && ./magiskboot cleanup"
```

`test_after` phải là `0` và ramdisk phải còn `init` và `apex`.

Patch. Dùng `KEEPFORCEENCRYPT=false` vì `/data` của các máy này không mã hóa (`getprop ro.crypto.state` = `unsupported`). Bật mã hóa có thể khiến máy đòi format data.

```sh
adb -s $S shell "cd $T && KEEPVERITY=false KEEPFORCEENCRYPT=false RECOVERYMODE=false \
  sh boot_patch.sh clean-boot.img; echo patch=\$?"
```

Log đúng phải có: `Stock boot image detected` và `Backup [init] -> [.backup/init.xz]`. Dòng `Failed to patch` khi đọc dtb là bình thường (dtb không chứa fstab).

```sh
adb -s $S pull $T/new-boot.img "$D/boot-magisk-v31.1.img"
adb -s $S pull $T/clean-boot.img "$D/boot-clean.img"
shasum -a 256 "$D"/boot-magisk-v31.1.img "$D"/boot-clean.img
```

## Bước 4: Kiểm tra image trên Mac trước khi nạp

Tách kernel và ramdisk (boot header v0) bằng script này, lưu ngoài repo, ví dụ `unpack.py`:

```python
import struct, sys
d = open(sys.argv[1], 'rb').read()
assert d[:8] == b'ANDROID!'
ks, _, rs, _, ss, _, _, ps = struct.unpack('<8I', d[8:40])
pad = lambda n: (n + ps - 1) // ps * ps
open('kernel', 'wb').write(d[ps:ps + ks])
r = ps + pad(ks)
open('ramdisk', 'wb').write(d[r:r + rs])
print('page', ps, 'kernel', ks, 'ramdisk', rs, 'cmdline', d[64:576].rstrip(b'\0'))
```

```sh
mkdir orig new
(cd orig && python3 -I ../unpack.py "$D/boot-before-root.img" && mkdir rd && cd rd && gzip -dc ../ramdisk | cpio -idm)
(cd new  && python3 -I ../unpack.py "$D/boot-magisk-v31.1.img" && mkdir rd && cd rd && gzip -dc ../ramdisk | cpio -idm && chmod -R u+rwx .)
cmp orig/kernel new/kernel && echo kernel-giong
xz -dc new/rd/.backup/init.xz | cmp - orig/rd/init && echo init-goc-dung
ls -a new/rd new/rd/.backup; cat new/rd/.backup/.magisk
```

Cả 4 điều sau phải đúng:

1. Kernel giống hệt kernel trong `boot-before-root.img` (`cmp`).
2. Ramdisk có `init` (magiskinit), `.backup/init.xz`, `.backup/.magisk`, `overlay.d/sbin/magisk.xz`, `overlay.d/sbin/init-ld.xz`.
3. `xz -dc .backup/init.xz` giống hệt `init` trong ramdisk gốc.
4. Ramdisk có thư mục `apex`. `magiskinit` dựa vào nó để chọn đường khởi động hai giai đoạn của Android 10 (`check_two_stage` trong `native/src/init/getinfo.rs`). Thiếu thì nó rơi vào `RootFS Init` và kernel panic.

Sai bất kỳ điểm nào thì **không nạp**.

## Bước 5: Nạp trong TWRP

```sh
adb -s $S reboot recovery
adb -s $S shell 'id -u; getprop ro.boot.bootloader; getprop ro.boot.serialno; dd if=/dev/block/by-name/BOOT bs=1048576 2>/dev/null | sha256sum'
```

Hash phân vùng hiện tại phải bằng hash `boot-before-root.img`. Nếu khác thì máy đã bị đổi từ lúc sao lưu, dừng lại kiểm tra.

```sh
adb -s $S push "$D/boot-magisk-v31.1.img" /tmp/new-boot.img
adb -s $S shell 'sha256sum /tmp/new-boot.img'          # phải khớp hash trên Mac
adb -s $S shell 'dd if=/tmp/new-boot.img of=/dev/block/by-name/BOOT bs=1048576 conv=fsync; sync'
adb -s $S shell 'dd if=/dev/block/by-name/BOOT bs=1048576 2>/dev/null | sha256sum'   # đọc lại phải khớp
adb -s $S reboot
```

Chỉ ghi BOOT. Không wipe, không ghi RECOVERY/EFS/modem/bootloader.

## Bước 6: Kiểm tra và cấp quyền

```sh
# chờ getprop sys.boot_completed = 1
adb -s $S shell 'magisk -v; magisk -V; which su'
adb -s $S install "$D/Magisk-v31.1.apk"
```

**Magisk v31.1 không hiện bảng hỏi khi có yêu cầu su.** Mặc định từ chối, logcat ghi `W Magisk: su: request rejected (2000)`. Phải cấp quyền tay:

App Magisk → tab **Superuser** → nút **+** (Grant Superuser) → tích **Shell** (`com.android.shell`). Chỉ cấp cho Shell, không cấp cho app khác.

Tự động qua ADB được (đã làm thành công): mở app, `uiautomator dump` để tìm nút có `content-desc="Grant Superuser"`, bấm, rồi bấm checkbox trên dòng `com.android.shell`. Tọa độ phụ thuộc màn hình nên luôn tìm lại bằng `uiautomator`, không cố định.

```sh
adb -s $S shell 'su -c "id; getenforce; magisk -V"'
```

Kết quả đúng: `uid=0(root) ... context=u:r:magisk:s0`, `Enforcing`, `31100`.

Dọn file tạm: `adb -s $S shell rm -rf /data/local/tmp/pf-root`. Ghi trạng thái vào `root-operation.json` trong `$D`.

## Quay về khi lỗi

- **Bootloop / logo Samsung lặp:** giữ Vol Up + Bixby + Power để vào TWRP, rồi:

  ```sh
  adb -s $S push "$D/boot-before-root.img" /tmp/boot.img
  adb -s $S shell 'sha256sum /tmp/boot.img; dd if=/tmp/boot.img of=/dev/block/by-name/BOOT bs=1048576 conv=fsync; sync; dd if=/dev/block/by-name/BOOT bs=1048576 2>/dev/null | sha256sum'
  adb -s $S reboot
  ```

  Lấy log lỗi trước khi khôi phục: `adb -s $S shell cat /sys/fs/pstore/console-ramoops*` hoặc `/proc/last_kmsg`.
- **Bỏ root:** làm giống hệt trên (nạp lại `boot-before-root.img`) rồi gỡ app Magisk.
- **Kẹt Download Mode (màn hình xanh):** cần người cầm máy. Giữ Vol Down + Power để thoát, rồi ngay lập tức Vol Up + Bixby + Power để vào TWRP. Heimdall/samloader trên Mac từng lỗi handshake trước khi ghi nên đừng trông vào chúng.

## Lỗi đã gặp: bootloop 3 lần ngày 08/11/2026

Triệu chứng: `last_kmsg` ghi `magiskinit: RootFS Init`, không tìm thấy `init.rc` và `/init`, rồi `Kernel panic - not syncing: Attempted to kill init`.

Nguyên nhân: ramdisk boot gốc của máy có `.backup/.magisk` (cấu hình `KEEPFORCEENCRYPT=false`, `KEEPVERITY=false`), sót lại từ một lần dùng Magisk trước, nhưng không có bản sao `init`. `magiskboot cpio test` trả `1` vì thấy `.backup/.magisk`. `boot_patch.sh` vì vậy chạy `restore`. Trong `native/src/boot/cpio.rs`, `restore` thấy danh sách backup rỗng nên gọi `entries.clear()` và xóa toàn bộ ramdisk, kể cả `/init` và `/apex`. Magisk sau đó patch một ramdisk rỗng, `magiskinit` không có init gốc để chuyển tiếp và chọn nhánh RootFS.

Hai lần thử sau, thêm `skip_initramfs` vào cmdline và `RECOVERYMODE=true`, chỉ chữa triệu chứng nên vẫn hỏng. Cách sửa đúng là bước 3: xóa `.backup` sót lại trước khi patch. Ba image hỏng vẫn để trong thư mục S9-G960N kèm file `DO-NOT-FLASH-FAILED-IMAGES.txt`. Không nạp lại chúng.

## Ghi chú cho máy tiếp theo

- Máy S9 này có công cụ khác tự đổi `ro.build.fingerprint` (08/11 báo `G955N`, 11/11 báo `N935K`) trong khi `ro.odm.build.fingerprint` vẫn là firmware thật `G960NKSU5FUG4`. Đọc fingerprint thật từ `ro.odm.build.fingerprint` hoặc `ro.boot.bootloader`, không tin `ro.build.fingerprint`.
- `/system/build.prop` trên ROM này không đọc được bằng user shell. Đó là dấu hiệu ROM đã bị sửa, không phải lỗi ADB.
- Đồng hồ máy có thể sai (máy này báo tháng 03/2026). Không dùng thời gian trên máy để đặt tên file.
- Bản ghi đầy đủ của lần này: `~/Library/Application Support/Phone Farm/device-maintenance/S9-G960N-20261108/root-operation.json`.

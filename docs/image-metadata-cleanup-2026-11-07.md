# Xóa metadata app_store.png — 07/11/2026

Đã gỡ C2PA/caBX và các trường EXIF, văn bản, thời gian nếu có. Không thêm nhãn Screenshot, ngày chụp hoặc nguồn tạo giả. Giữ nguyên dữ liệu pixel và các khối cần để hiển thị màu.

Các bản đồng bộ:
- `/Users/vinhtran_1/Downloads/hoanxu-mac-dinh-2026-11-07/anh-mac-dinh/app_store.png`
- `/Users/vinhtran_1/Documents/phone-farm/Resources/ThreadsDefaults/images/app_store.png`
- `/Users/vinhtran_1/Library/Application Support/Phone Farm/threads-images/app_store.png`
- `/Users/vinhtran_1/Documents/phone-farm/.build/Phone Farm.app/Contents/Resources/ThreadsDefaults/images/app_store.png`

SHA-256 mới: `716f8c9cb1ea59d1fc3fbbd9e1bf23f4797a52e5e8eac943f6fb4ea87fdc6a5e`

Các chunk còn lại: IHDR, IDAT, IEND.

Dữ liệu IDAT trước/sau giống hệt; không nén lại ảnh. Bản gốc dự phòng: `/Users/vinhtran_1/Documents/phone-farm/.build/metadata-backup/20261107-220151`.

15 ảnh hoan-xu khác không thay đổi. Báo cáo image-metadata-2026-11-07.md mô tả trạng thái trước khi xóa. Ảnh vẫn có nguồn gốc AI dù metadata đã được gỡ.

Đã ký lại app hiện tại và kiểm tra codesign --verify --strict thành công. Build đầy đủ bị chặn bởi lỗi Java hiện có trong android/KeyboardTyper.java; không sửa mã Java trong tác vụ metadata này.

# Kiểm tra metadata ảnh — 07/11/2026

Kiểm tra trực tiếp cấu trúc PNG và các trường nhúng, không thay đổi ảnh.

## app_store.png

- Kích thước: 1024 × 1536.
- Có khối caBX chứa C2PA.
- softwareAgent: ChatGPT; version: gpt-image.
- claim generator: OpenAI Media Service API.
- digitalSourceType: http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia.
- c2pa.created: 2026-11-02T17:42:37.466899942Z.
- Metadata ghi ảnh được tạo bởi AI. Chưa kiểm tra mật mã chữ ký C2PA.

## hoan-xu-01.png đến hoan-xu-15.png

| Tệp | Kích thước | UserComment | DateCreated |
| --- | --- | --- | --- |
| hoan-xu-01.png | 1170 × 2532 | Screenshot | 2026-10-30T00:15:15 |
| hoan-xu-02.png | 1170 × 2532 | Screenshot | 2026-10-30T00:15:41 |
| hoan-xu-03.png | 1170 × 2532 | Screenshot | 2026-11-03T00:19:01 |
| hoan-xu-04.png | 1170 × 2532 | Screenshot | 2026-11-03T00:19:15 |
| hoan-xu-05.png | 1170 × 2532 | Screenshot | 2026-11-03T00:19:21 |
| hoan-xu-06.png | 1170 × 2532 | Screenshot | 2026-11-03T00:19:31 |
| hoan-xu-07.png | 1170 × 2532 | Screenshot | 2026-11-03T00:19:39 |
| hoan-xu-08.png | 1170 × 2532 | Screenshot | 2026-11-03T00:19:44 |
| hoan-xu-09.png | 1170 × 2532 | Screenshot | 2026-11-03T00:19:49 |
| hoan-xu-10.png | 1170 × 2532 | Screenshot | 2026-11-03T00:19:54 |
| hoan-xu-11.png | 1170 × 2532 | Screenshot | 2026-11-03T00:19:59 |
| hoan-xu-12.png | 1170 × 2532 | Screenshot | 2026-11-03T00:20:04 |
| hoan-xu-13.png | 1170 × 2532 | Screenshot | 2026-11-03T00:20:08 |
| hoan-xu-14.png | 1170 × 2532 | Screenshot | 2026-11-03T00:20:36 |
| hoan-xu-15.png | 1170 × 2532 | Screenshot | 2026-11-03T00:20:47 |

Cả 15 ảnh có EXIF/XMP ghi Screenshot, không có khối caBX/C2PA hay trường ghi công cụ sinh ảnh AI trong metadata đã đọc. Điều này phù hợp với ảnh chụp màn hình, nhưng không chứng minh nội dung bên trong chưa từng qua AI hoặc chỉnh sửa.

Bộ ảnh trong mã nguồn và app build được đối chiếu SHA-256 với thư mục gốc; khớp cả 16 tệp.

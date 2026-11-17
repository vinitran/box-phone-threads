# Quyền ảnh và gõ bio — 17/11/2026

App local **0.1.43 / build 43** bổ sung vào cả chỉnh hồ sơ tự động và chỉnh bio thủ công:

- Khi mở thư viện, tự bấm Bật trong gallery của Threads và Cho phép trên hộp quyền ảnh
  Android nếu nhận diện đúng app Threads và phạm vi ảnh/media/storage. Không dùng pm grant.
  Chỉ thử một lần mỗi nút, không liên tục yêu cầu lại nếu người dùng từ chối.
- Nếu không xác định chắc hộp quyền/nút Cho phép hoặc bấm không thành công, chờ 15 giây
  tính từ khi thấy hộp quyền, hiển thị đếm ngược. Sau đó còn tối đa 5 giây tải gallery.
  Cấp quyền xong tiếp tục cùng luồng; hết hạn vẫn có hộp quyền thì báo cần cấp quyền.
- Nhận diện các permission controller Android/Google/Samsung và package installer cũ.
  Không tự cho phép prompt app khác hoặc yêu cầu camera, vị trí, microphone, danh bạ.
- Bio dùng mở ô nhập → xoá bản cũ trong editor → gõ từng phím Gboard Telex ở nhịp
  140–260 ms giống comment → xác minh nội dung trong màn Edit bio → bấm Next và lưu hồ sơ.
  Không dùng ACTION_SET_TEXT để chèn bio mới. ACTION_SET_TEXT chỉ dùng xoá nội dung cũ.
- Bio được chuẩn hoá thành nội dung có thể gõ, giới hạn một dòng/150 ký tự trước khi sửa.
  Lỗi chuẩn bị/gõ hoặc bấm Dừng sẽ không sang bước lưu. Avatar và bio tự động vẫn lưu
  chung trong Edit profile, chờ upload ảnh như trước.
- Giữ kiểm tra Android user, deadline và marker huỷ trong các bước đợi/bấm/gõ.

Kiểm tra: **67 test Swift qua**, gồm 4 test mới cho thứ tự prepare/type/save, chuẩn hoá,
bio không hợp lệ, lỗi giữa chừng và cancellation. `python3 scripts/test-gallery-permission.py`
chạy hai lớp Java production qua clock/prompt fixtures: đủ 15 giây, 5 giây tải gallery,
timeout hữu hạn, whitelist controller, prompt Anh/Việt và từ chối quyền không liên quan.
Build app biên dịch toàn bộ Java và đóng cả GalleryWait/GalleryPermission vào DEX.

Chưa thử đổi bio/avatar hoặc thu hồi quyền trên tài khoản thật trong QA này. Test fixture
không thay thế kiểm tra UI trên mọi bản ROM/ngôn ngữ; prompt chưa nhận diện dùng chờ thủ công.
Không chạy bình luận tự động khi mở app để kiểm tra nút mới.

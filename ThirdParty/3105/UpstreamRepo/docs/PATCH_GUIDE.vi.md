# Hướng dẫn Patch workspace

Patch của 3105 nhắm đến ứng dụng bằng bundle identifier ổn định. Gói patch không lưu UUID container vì UUID này thay đổi theo từng máy và mỗi lần cài lại ứng dụng.

## Cấu trúc workspace

Khi tạo patch tên `ABC` cho bundle `com.abc.xyz`, 3105 tạo cây thư mục có thể chỉnh sửa như sau:

```text
Trên iPhone của tôi/
└── 3105/
    └── Patches/
        └── ABC/
            └── com.abc.xyz/
                ├── Documents/
                │   └── config.json
                └── Library/
                    └── Preferences/
                        └── com.abc.xyz.plist
```

Mọi thứ bên dưới folder bundle là đường dẫn tương đối trong data container của ứng dụng. Folder cấp đầu tiên bắt buộc phải là bundle identifier hợp lệ, không phải UUID container và không phải đường dẫn tuyệt đối `/var/mobile/...`.

## Tạo patch

### Tạo từ tab Patch

1. Mở **Patch**, bấm **+**, sau đó chọn **Tạo patch**.
2. Nhập tên dự án và bundle identifier của ứng dụng đích.
3. Có thể đặt mật khẩu. Mật khẩu của gói không thể đổi sau khi tạo.
4. Bấm **Xong**. 3105 sẽ tạo dự án và workspace có thể chỉnh sửa.
5. Mở **Tệp → Workspace 3105 → Patches → tên patch → bundle ID**.
6. Tạo đúng cây đường dẫn đích rồi đặt file thay thế vào vị trí tương ứng.

Ví dụ muốn thay `Library/Preferences/com.abc.xyz.plist`, hãy đặt file mới đúng tại đường dẫn đó bên trong folder `com.abc.xyz`. Nếu muốn thêm cả folder, hãy chép folder vào đúng thư mục cha; mọi file thường bên trong sẽ trở thành nội dung của patch.

### Tạo nhanh từ file hoặc folder của ứng dụng

1. Mở **Tệp**, vào data container của ứng dụng rồi tìm file hoặc folder đích.
2. Giữ vào mục đó và chọn **Tạo patch**.
3. 3105 tự lấy bundle identifier ổn định và đường dẫn tương đối, sau đó mở bản nháp patch.
4. Lưu bản nháp, mở workspace rồi thay hoặc sắp xếp lại nội dung đã lấy theo nhu cầu.

## Áp dụng và khôi phục

- **Áp dụng** sẽ đồng bộ workspace vào gói `.3105` đã mã hóa, tìm container hiện tại bằng bundle identifier và kiểm tra an toàn từng đường dẫn.
- File đã tồn tại được sao lưu trước khi bị thay. File chưa tồn tại sẽ được thêm mới.
- Toàn bộ lần ghi có nhật ký và kiểm tra lại dữ liệu. Nếu lỗi giữa chừng, 3105 sẽ cố gắng rollback giao dịch.
- **Khôi phục file gốc** trả lại file đã có trước khi áp dụng, xóa file do patch thêm và xóa các folder do patch tạo sau khi chúng đã rỗng.
- Nếu file hiện tại hoặc dữ liệu khôi phục không còn khớp với nhật ký, app sẽ dừng an toàn thay vì ghi đè một đích chưa được xác minh.

Nên đóng ứng dụng đích trong lúc áp dụng hoặc khôi phục patch. Không đổi tên folder bundle và không đưa file ra ngoài folder đó.

## Xuất, nhập và mật khẩu

- **Xuất** luôn đồng bộ nội dung mới nhất trong workspace trước khi chia sẻ file `.3105`.
- Có thể nhập từ ứng dụng Tệp bằng cách mở hoặc chia sẻ gói `.3105` sang 3105.
- Website có thể mở app bằng `threeoneosfive://import?url=<URL HTTPS đã percent-encode>`. App chỉ nhận URL HTTPS không chứa tài khoản hoặc mật khẩu nhúng.
- Trên máy hoặc lần cài mới, gói có bảo vệ sẽ hỏi mật khẩu một lần. 3105 lưu content key đã mở khóa trong Keychain; file xuất ra vẫn được mã hóa và luôn gắn với mật khẩu ban đầu.
- Patch v1 cũ vẫn sử dụng được. App không âm thầm ghi lại gói v1 thành v2 chỉ vì người dùng mở nó.

## Quy tắc an toàn

- Chỉ dùng patch với ứng dụng và dữ liệu thuộc sở hữu của bạn.
- Luôn giữ một bản sao lưu riêng cho dữ liệu quan trọng.
- 3105 từ chối symbolic link, đường dẫn tuyệt đối, thành phần `..`, bundle không hợp lệ và nhiều mục trỏ đến cùng một đích.
- Bản 1.0.1 bỏ giới hạn cố định cũ về tổng dung lượng payload và số file; dung lượng trống, RAM, filesystem và giới hạn của iOS vẫn được áp dụng.
- Quyền truy cập trên thiết bị vẫn yêu cầu đúng build iOS được hỗ trợ và cách ký chứng chỉ doanh nghiệp được ghi trong README.

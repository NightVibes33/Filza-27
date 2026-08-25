# Định dạng kho 3105 v1

Kho 3105 là một tệp JSON công khai qua HTTPS. Ứng dụng đọc metadata
trong kho, nhưng vẫn coi toàn bộ dữ liệu và gói tải xuống là không đáng tin cậy.

## Danh sách nguồn mặc định

3105 đồng bộ danh sách nguồn mặc định từ:

```text
https://raw.githubusercontent.com/YangJiiii/3105-repo/main/sources.json
```

Định dạng catalog:

```json
{
  "schemaVersion": 1,
  "sources": [
    "repositories/demo/repo.json",
    "https://example.com/3105/repo.json"
  ]
}
```

URL tương đối được tính từ vị trí cuối cùng của `sources.json`. Khi đồng bộ,
ứng dụng chỉ thêm URL mới và giữ nguyên các nguồn người dùng đã có; catalog
không được phép xoá nguồn khỏi thiết bị. Mỗi URL vẫn phải vượt qua chính sách
HTTPS và kiểm tra manifest như nguồn được thêm thủ công.

## Quy trình cài đặt

1. Người dùng thêm URL đầy đủ của `repo.json` trong tab **Nguồn**.
2. 3105 kiểm tra schema, URL, định danh, checksum và dải iOS.
3. Khi cài, gói `.3105` hoặc `.tendies` được tải về tệp tạm theo trường `kind`.
4. Patch `.3105` luôn được đối chiếu SHA-256 rồi kiểm tra UUID, trạng thái mật
   khẩu và bundle đích từ payload. Wallpaper `.tendies` được đối chiếu SHA-256,
   hoặc phải là URL Nugget-Wallpapers ghim vào commit GitHub 40 ký tự.
5. Patch hợp lệ được chuyển vào thư viện patch. Wallpaper tiếp tục qua bộ kiểm
   tra ZIP, symlink, dung lượng và descriptor rồi xuất hiện trong **Đã cài** để
   người dùng mở và áp dụng.

## Ví dụ

```json
{
  "schemaVersion": 1,
  "identifier": "com.example.repository",
  "name": "Example Repository",
  "description": "Các patch dành cho 3105",
  "icon": "assets/repository.png",
  "packages": [
    {
      "identifier": "clean-layout",
      "kind": "patch",
      "name": "Clean Layout",
      "author": "Example Developer",
      "version": "1.0.0",
      "summary": "Giao diện gọn hơn cho ứng dụng ví dụ.",
      "description": "Mô tả chi tiết có thể bỏ trống.",
      "category": "Customization",
      "tags": [
        "Wallpaper",
        "Minimal"
      ],
      "publishedAt": "2026-08-21T08:00:00Z",
      "icon": "assets/clean-layout.png",
      "banner": "assets/clean-layout-banner.png",
      "screenshots": [
        "assets/clean-layout-1.png",
        "assets/clean-layout-2.png"
      ],
      "download": "packages/clean-layout.3105",
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "size": 123456,
      "supportedOS": [
        {
          "minimum": "17.0",
          "maximum": "18.7.1"
        },
        {
          "minimum": "26.0",
          "maximum": "26.6.1"
        },
        {
          "minimum": "27.0",
          "maximum": "27.0",
          "builds": [
            "24A5390f"
          ]
        }
      ],
      "changelog": "Bản phát hành đầu tiên.",
      "featured": true,
      "isPrivate": false,
      "password": "mat-khau-do-chu-repo-chia-se"
    }
  ]
}
```

`icon`, `banner`, từng phần tử trong `screenshots` và `download` có thể là URL
HTTPS đầy đủ hoặc đường dẫn tương đối so với URL cuối cùng của `repo.json`.

`screenshots` là trường tuỳ chọn, tối đa 12 ảnh và giữ nguyên thứ tự khai báo.
Ảnh được hiển thị thành dải xem trước ngang ngay trong phần **Mô tả** của trang
chi tiết gói. Nên dùng ảnh PNG/JPEG/WebP dọc, cùng tỷ lệ và độ phân giải giữa
các ảnh để giao diện ổn định; nguồn cũ không có trường này vẫn hoạt động bình
thường.

`kind` nhận `patch` hoặc `wallpaper`. Nếu bỏ trống, ứng dụng mặc định là
`patch` để tương thích repo cũ. Package `wallpaper` bắt buộc dùng file
`.tendies`; sau khi tải sẽ nằm trong mục **Đã cài**, không đi qua patch engine.

`tags` là danh sách nhóm do người tạo nguồn đặt. Trong ứng dụng, người dùng mở
Nguồn → chọn tag → xem các patch thuộc tag đó. `category` cũ vẫn được tự động
coi là một tag nên repo v1 trước đây không cần sửa ngay.

`publishedAt` là ngày phát hành theo chuẩn ISO 8601. Home dùng trường này để
hiển thị mục **Mới nhất** theo đúng thứ tự thời gian. Gói không khai báo ngày
được xếp sau các gói có ngày thay vì bị ẩn. Home và Mới nhất chỉ hiển thị tối
đa 10 gói; người dùng vẫn có thể xem toàn bộ tại Nguồn hoặc Tìm kiếm.

`password` chỉ dành cho package `patch` và là trường tuỳ chọn. Nếu chủ repo
chủ động công khai trường này, 3105 dùng đúng giá trị đó để tự mở khoá gói sau
khi tải; mật khẩu không được lưu lại, chỉ content key được giữ trong Keychain.
Nếu gói có mật khẩu nhưng repo không khai báo `password`, ứng dụng mở màn hình
nhập mật khẩu và hướng dẫn người dùng liên hệ chủ repo. Không đặt `password`
cho package `wallpaper`.

## Trường bắt buộc

- `schemaVersion`: hiện tại phải là `1`.
- `identifier`: định danh ổn định, chỉ gồm chữ, số, `.`, `-`, `_`.
- `sha256`: chuỗi SHA-256 64 ký tự hexa của đúng tệp tải xuống. Chỉ wallpaper
  từ `SerStars/Nugget-Wallpapers` với URL `raw.githubusercontent.com` ghim vào
  commit GitHub 40 ký tự mới được phép bỏ trường này; file vẫn phải vượt qua
  toàn bộ bộ kiểm tra `.tendies` trước khi nhập.
- `supportedOS`: ít nhất một dải tương thích nên được khai báo. Nếu bỏ trống,
  3105 hiển thị trạng thái chưa xác định và không cho cài.

`packageID` và `bundleIdentifiers` không còn bắt buộc. Nguồn cũ vẫn có thể giữ
hai trường này, nhưng 3105 coi file `.3105` đã tải xuống là dữ liệu chính xác:
UUID, trạng thái mật khẩu và bundle đích chỉ được xác nhận từ gói thật.

## Patch riêng tư

Đặt `isPrivate` thành `true` để trang nguồn báo đây là patch riêng tư. Không cần
đưa bundle đích vào metadata kho. Tệp, bundle và đường dẫn nằm trong payload đã
mã hoá của `.3105`; ứng dụng chỉ đọc chúng sau khi người dùng mở khoá thành công.

## Quy tắc an toàn

- Chỉ HTTPS, cổng mặc định hoặc 443.
- Không chấp nhận credentials trong URL, localhost, miền `.local` hay địa chỉ IP.
- Redirect sang URL không đạt các điều kiện trên bị huỷ.
- Metadata trùng `identifier`, SHA-256 sai hoặc dải iOS sai bị từ chối.
- Patch không đúng checksum hoặc không có envelope `.3105` hợp lệ không được
  chuyển vào patch engine. Wallpaper không đúng `.tendies`, vượt giới hạn hoặc
  có archive/descriptor không an toàn không được đưa vào **Đã cài**.

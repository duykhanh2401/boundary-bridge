# Boundary Bridge

App native macOS thay thế giao diện Boundary Desktop cho luồng đăng nhập, chọn TCP target và kết nối qua **port localhost cố định**. SwiftUI + BSD sockets/DispatchSource, không dùng npm, Electron hay thư viện bên ngoài.

```text
Ứng dụng / database client
         │ 127.0.0.1:15432 (cố định)
         ▼
  Boundary Bridge — TCP forwarder
         │ 127.0.0.1:xxxxx (Boundary cấp tự động)
         ▼
  Boundary CLI → Worker → Target
```

## Sử dụng

Tải bản đóng gói tại [GitHub Releases](https://github.com/duykhanh2401/boundary-bridge/releases/latest). File `Boundary-Bridge-1.1.1-macos-arm64.zip` dành cho Mac Apple Silicon (M1 trở lên), yêu cầu macOS 13+. Giải nén rồi kéo **Boundary Bridge.app** vào Applications. Bản phát hành kèm Boundary CLI và license tương ứng; app ký ad-hoc, chưa được Apple notarize nên macOS có thể chặn lần mở đầu tiên. Mac Intel cần tự build từ mã nguồn trên máy Intel.

Các bước bên dưới dùng đường dẫn `dist/` khi build từ mã nguồn; nếu tải bản phát hành, mở app đã giải nén hoặc app trong Applications.

1. Mở `dist/Boundary Bridge.app`. Có thể kéo vào Applications.
2. Chọn **Boundary**, nhập **Controller URL** giống app Boundary cũ. Bật VPN trước nếu hệ thống yêu cầu.
3. Nhập **Scope ID** (`global` mặc định; dùng `o_…` nếu tổ chức giới hạn quyền liệt kê). Chọn **Tải phương thức**, chọn phương thức đăng nhập. Có thể nhập Auth Method ID trực tiếp nếu không được cấp quyền liệt kê.
4. Đăng nhập bằng **SSO/OIDC**, **mật khẩu** hoặc **LDAP**. SSO mở trình duyệt; macOS có thể hỏi quyền truy cập Keychain của CLI.
5. Vào **Targets → Tải targets → Gán port**. Đặt tên và port cố định, ví dụ PostgreSQL `15432`, Redis `16379`, MySQL `13306`.
6. Vào **Kết nối → Kết nối**. Cấu hình dịch vụ của bạn dùng `127.0.0.1` và port đã đặt.

Đóng cửa sổ vẫn giữ tunnel chạy trên thanh menu. **Thoát** sẽ dừng tất cả tunnel và giải phóng port. Không tự kết nối khi mở app. Nút **Đăng xuất** ngắt các tunnel và yêu cầu CLI thu hồi/xóa token tương ứng.

Mỗi target có một cấu hình riêng. Có thể **Kết nối tất cả / Ngắt tất cả**, chỉnh sửa khi đã ngắt, sao chép endpoint, xem số socket TCP và nhật ký. Target ID cũng có thể nhập trực tiếp, không bắt buộc có quyền liệt kê targets.

## Tài khoản đã lưu và OTP tự động (v1.1.1)

- Thanh bên nhận click trên toàn bộ hàng, gồm icon, chữ và khoảng trống; có trạng thái hover.
- Vào **Boundary → Tài khoản đã lưu → Thêm tài khoản**. Nhập tên gợi nhớ, username, mật khẩu và **khóa thiết lập OTP** (secret Base32 hoặc URI `otpauth://totp/…`). Không dùng mã 6 số đang hiển thị làm khóa.
- Với cấu hình OIDC có màn hình tài khoản/mật khẩu/ô OTP riêng, giữ kiểu **OIDC**. Chọn một tài khoản đã lưu để bắt đầu tự đăng nhập rồi tải targets. Ngắt tunnel trước khi đổi tài khoản.
- App mở phiên WebKit riêng, tự điền và submit form POST thông dụng cùng miền: username/mật khẩu rồi OTP. Mỗi bước chỉ tự gửi một lần, không lặp mật khẩu sai. Form tùy biến, CAPTCHA, xác nhận thiết bị, chuyển sang miền đăng nhập khác hoặc IdP không cho phép WebView có thể cần thao tác trong cửa sổ hoặc nút **Tiếp tục bằng trình duyệt ngoài**.
- Mỗi tài khoản có token CLI riêng và phiên cookie riêng. Mật khẩu/khóa OTP lưu ở Keychain; `config.json` chỉ chứa tên, username và thông tin phương thức/controller. Khóa OTP không truyền vào JavaScript, chỉ mã hiện tại được điền vào đúng origin HTTPS do Boundary trả về.
- TOTP hỗ trợ SHA1/SHA256/SHA512, 6 hoặc 8 chữ số; URI có thể chỉ định chu kỳ. App chờ mã mới nếu mã hiện tại sắp hết hạn.
- Sửa tài khoản: bỏ trống mật khẩu/OTP để giữ giá trị cũ; có tùy chọn xóa OTP. Xóa tài khoản sẽ xóa mật khẩu/khóa OTP đã lưu, không phải thao tác thu hồi token Boundary hiện có.
- Password/LDAP trực tiếp vẫn hỗ trợ lưu tài khoản; ghép OTP sau mật khẩu chỉ dùng khi máy chủ LDAP thực sự yêu cầu. Boundary password/LDAP không có tham số OTP riêng.

Bản 1.1.1 sửa bước tự điền OTP sau khi chuyển trang hoặc khi form OTP xuất hiện động, kể cả khi ô username/mật khẩu vẫn còn trên trang. Hỗ trợ OTP tách thành từng ô và nhận diện qua nhãn ô nhập. Nút Đăng nhập dùng tài khoản đã chọn (hoặc tài khoản duy nhất khớp cấu hình) để chạy luồng tự động.

Các nút bắt đầu tunnel, Kết nối tất cả và kết nối trên thanh menu bị khóa cho đến khi đăng nhập thành công. Đăng nhập đang xử lý, bị hủy hoặc thất bại không mở khóa kết nối.

Bản cập nhật được đóng gói tại `dist/v1.1.1/Boundary Bridge.app`. Thoát bản cũ rồi mở bản này; cấu hình target/port được giữ nguyên. Không chạy đồng thời hai phiên bản để tránh ghi đè cấu hình.

## Đăng nhập và CLI

Bản đóng gói trên máy này kèm Boundary CLI và `LICENSE.txt` từ Boundary Desktop đã cài. Không cần chạy hoặc giữ Boundary Desktop sau khi bản app có CLI đi kèm. Nếu không đóng gói CLI, chọn executable độc lập trong cài đặt; app cũng tự tìm Homebrew và Boundary Desktop.

CLI giữ trách nhiệm xác thực, Keychain, chính sách phiên và giao thức tunnel. App gọi executable bằng mảng arguments, không qua shell. CLI sử dụng token riêng tên `BoundaryBridge` mặc định; muốn dùng token CLI đã có thì chọn đúng tên token đó. Token đăng nhập của Boundary Desktop cũ không được tự động nhập vào app.

Với password/LDAP, mật khẩu chỉ truyền bằng biến môi trường của tiến trình đăng nhập, không đưa vào arguments. Với OIDC tự động, mật khẩu điền vào form HTTPS trong WebKit. Thông tin tài khoản đã lưu nằm trong Keychain. Output đăng nhập không được ghi log; riêng URL OIDC được chuyển trong bộ nhớ cho WebKit, token do CLI lưu vào Keychain. Cấu hình trong `~/Library/Application Support/BoundaryBridge/config.json` chỉ chứa các trường thiết lập và metadata tài khoản, quyền file `0600`. Không lưu raw JSON session vì có thể chứa credentials. Nhật ký giới hạn 200 dòng/kết nối và che các mẫu secret thông thường; không chứa payload TCP.

## Hành vi forwarding

- Chỉ bind **IPv4 `127.0.0.1`**, port cố định `1024–65535`; cấu hình client dùng địa chỉ này. Không mở ra LAN.
- Đặt trước port cố định rồi chạy `boundary connect -format=json -listen-addr=127.0.0.1 -listen-port=0`. Port trùng hoặc đã bị ứng dụng khác chiếm sẽ báo lỗi.
- Chuyển tiếp hai chiều theo từng khối 64 KiB, có backpressure và TCP half-close; tối đa 512 socket/kết nối cấu hình.
- Khi CLI dừng, đóng các socket cũ và thử lại sau 2, 4, 8, 16, 30, 30 giây nếu bật tự kết nối lại. Phiên chạy ổn định ít nhất 30 giây sẽ reset số lần thử. Dừng sau 6 lần thất bại liên tiếp để người dùng kiểm tra tài khoản/VPN.
- Giữ listener cố định trong thời gian retry; các kết nối tới lúc chưa có tunnel bị đóng. Sau khi có port Boundary mới, các kết nối TCP mới đi qua port mới.
- **Không khôi phục được socket/giao dịch đang chạy** khi tunnel đứt. Ứng dụng/database pool cần cơ chế reconnect riêng. App không vượt giới hạn thời gian/quyền/connection limit của Boundary.
- Chế độ tùy chọn **Port từ Boundary Desktop** chỉ forward một port đã biết; phải sửa port nguồn khi Desktop cấp port mới. Luồng thay thế client sử dụng chế độ **Boundary CLI (tự động)**.

## Build và kiểm tra

Yêu cầu macOS 13+, Swift 5.9+ và Xcode Command Line Tools. Build theo kiến trúc máy hiện tại.

```sh
./scripts/check.sh
node scripts/check-autofill.mjs
# Native WebKit regression checks; run in a macOS desktop session
swift build --product BrowserChecks
.build/debug/BrowserChecks
# Optional: creates and removes only synthetic test Keychain entries
.build/debug/BridgeChecks --keychain
./scripts/build-app.sh
open 'dist/Boundary Bridge.app'
```

Bộ 17 checks (18 khi bật `--keychain`) dùng Foundation để chạy được trên Command Line Tools không có XCTest. Kiểm tra OTP bằng 18 test vectors RFC 6238, migration cấu hình cũ, tách secrets, OIDC helper, parser JSON phân mảnh/UTF-8, giới hạn output, validation/cấu hình/permissions, arguments, che secret, dữ liệu targets, luồng auth/discovery/logout bằng CLI giả; và dùng socket TCP thật để kiểm tra nhiều target độc lập, đồng thời 4 client truyền tổng 4.8 MB, half-close, giải phóng port, port bị chiếm, cấp port mới khi reconnect, hủy retry. 9 checks JavaScript riêng dùng DOM giả để kiểm tra autofill, chống gửi lặp, ô OTP riêng, origin/action và dữ liệu chứa ký tự đặc biệt. 8 checks WebKit native kiểm tra DOM thật, chuyển trang và form động với chính bộ điều phối đăng nhập của app; chỉ dùng dữ liệu giả. Node chỉ cần cho checks JavaScript, không phải dependency của app.

CLI giả chỉ chạy trên localhost, không gọi controller thật hoặc đọc token. Đăng nhập SSO/LDAP/password và kết nối controller thực tế cần kiểm tra với hệ thống của bạn; không có tài khoản/controller được cấu hình sẵn.

App được ký ad-hoc để chạy nội bộ, chưa notarize để phân phối rộng rãi. Build script giữ nguyên binary/license CLI; sản phẩm Boundary gốc không bị sửa hoặc gỡ cài đặt. Phiên bản này tập trung **TCP targets**, chưa triển khai tính năng transparent sessions, SSH credential injection hay giao diện quản trị Boundary.

## Tài liệu giao thức

- [Boundary connect](https://developer.hashicorp.com/boundary/docs/commands/connect)
- [CLI output và token storage](https://developer.hashicorp.com/boundary/docs/commands)
- [Session JSON của Boundary CLI](https://github.com/hashicorp/boundary/blob/main/internal/cmd/commands/connect/connect.go)
- [RFC 6238: TOTP và test vectors](https://www.rfc-editor.org/rfc/rfc6238.html)

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'USAGE'
Usage: scripts/package-release.sh --app PATH --output DIRECTORY [options]

Default: Developer ID signing + Apple notarization + stapling + Gatekeeper check.
  --identity NAME         Full Developer ID Application identity in your Keychain
  --notary-profile NAME   Credentials previously stored by notarytool
  --adhoc                 Package for internal use; macOS will still warn users

The source app is never modified. Existing release artifacts are not overwritten.
USAGE
}
fail() { echo "Error: $*" >&2; exit 1; }
app=""; output=""; identity=""; profile=""; adhoc=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app|--output|--identity|--notary-profile)
      [[ $# -ge 2 && -n "$2" ]] || fail "Missing value for $1"
      case "$1" in
        --app) app="$2";;
        --output) output="$2";;
        --identity) identity="$2";;
        --notary-profile) profile="$2";;
      esac
      shift 2;;
    --adhoc) adhoc=true; shift;;
    --help|-h) usage; exit 0;;
    *) usage >&2; fail "Unknown argument: $1";;
  esac
done
[[ -n "$app" && -n "$output" ]] || { usage >&2; exit 1; }
[[ -f "$app/Contents/Info.plist" && -x "$app/Contents/MacOS/BoundaryBridge" ]] || fail "Not a Boundary Bridge app: $app"
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid app version"
archs=$(lipo -archs "$app/Contents/MacOS/BoundaryBridge")
case "$archs" in
  arm64|x86_64) arch="$archs";;
  *) fail "Unsupported architecture list: $archs";;
esac
if "$adhoc"; then
  [[ -z "$identity" && -z "$profile" ]] || fail "Do not combine --adhoc with signing credentials"
  suffix="-unnotarized"
else
  [[ "$identity" == "Developer ID Application: "* ]] || fail "Supply --identity 'Developer ID Application: …' (Apple Developer Program required), or explicitly use --adhoc"
  [[ -n "$profile" ]] || fail "Supply --notary-profile with credentials stored by xcrun notarytool store-credentials"
  identities=$(security find-identity -v -p codesigning)
  [[ "$identities" == *\""$identity"\"* ]] || fail "Signing identity not available in Keychain: $identity"
  xcrun --find notarytool >/dev/null
  xcrun --find stapler >/dev/null
  suffix=""
fi

mkdir -p "$output"
output=$(cd "$output" && pwd)
archive="Boundary-Bridge-${version}-macos-${arch}${suffix}.zip"
for artifact in "$archive" SHA256SUMS.txt INSTALL.txt notarization.json; do
  [[ ! -e "$output/$artifact" ]] || fail "Output already exists: $output/$artifact; use a new directory"
done
staging=$(mktemp -d "$output/.package.XXXXXX")
trap 'rm -rf "$staging"' EXIT
staged_app="$staging/Boundary Bridge.app"
ditto "$app" "$staged_app"

if ! "$adhoc"; then
  # Preserve the vendor-signed Boundary CLI and its license. Sign the enclosing
  # app with hardened runtime; never use --deep to overwrite nested signatures.
  codesign --force --options runtime --timestamp --sign "$identity" "$staged_app"
  codesign --verify --deep --strict "$staged_app"
  ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$staging/submission.zip"
  xcrun notarytool submit "$staging/submission.zip" --keychain-profile "$profile" \
    --wait --output-format json > "$output/notarization.json"
  status=$(plutil -extract status raw -o - "$output/notarization.json")
  [[ "$status" == Accepted ]] || fail "Apple did not accept the submission. See $output/notarization.json and use notarytool log with the submission ID"
  xcrun stapler staple "$staged_app"
  xcrun stapler validate "$staged_app"
  spctl --assess --type execute --verbose=2 "$staged_app"
fi
codesign --verify --deep --strict "$staged_app"
# Archive AFTER stapling so the downloaded app carries its notarization ticket.
ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$staging/$archive"
cat > "$staging/INSTALL.txt" <<'INSTALL'
Boundary Bridge — cài đặt trên macOS

1. Giải nén ZIP và kéo Boundary Bridge.app vào Applications.
2. Thoát bản cũ trước khi mở bản mới. Tài khoản và cấu hình port được giữ nguyên.
3. Mở Boundary Bridge từ Applications.

SHA256SUMS.txt dùng để đối chiếu file tải xuống với bản do nhà phát hành cung cấp.
Kiểm tra trong thư mục chứa ZIP: shasum -a 256 -c SHA256SUMS.txt
INSTALL
if "$adhoc"; then
  cat >> "$staging/INSTALL.txt" <<'INSTALL'

Bản này CHƯA được Apple notarize; macOS có thể báo không xác minh nhà phát triển.
Nếu bạn tin cậy nguồn phát hành, sau khi thử mở app và thấy cảnh báo:
System Settings → Privacy & Security → Open Anyway → Open.
macOS lưu ngoại lệ cho riêng ứng dụng này. Máy do tổ chức quản lý có thể hạn chế
thao tác này. Không cần tắt Gatekeeper trên toàn hệ thống.
Hướng dẫn Apple: https://support.apple.com/en-us/102445
INSTALL
fi
(cd "$staging" && shasum -a 256 "$archive" > SHA256SUMS.txt)
mv "$staging/$archive" "$staging/SHA256SUMS.txt" "$staging/INSTALL.txt" "$output/"
echo "Release artifacts: $output"
if "$adhoc"; then
  echo "UNNOTARIZED: this ZIP still requires Open Anyway on downloaded copies. See INSTALL.txt."
else
  echo "Developer ID signed, notarized, stapled, and Gatekeeper assessment passed."
fi

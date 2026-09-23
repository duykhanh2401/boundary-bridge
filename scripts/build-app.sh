#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

skip_build=false
app="${BRIDGE_APP_OUTPUT:-dist/Boundary Bridge.app}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) skip_build=true; shift;;
    --output)
      if [[ $# -lt 2 || -z "$2" ]]; then echo "Missing --output path" >&2; exit 1; fi
      app="$2"; shift 2;;
    *) echo "Usage: $0 [--skip-build] [--output PATH]" >&2; exit 1;;
  esac
done

if ! "$skip_build"; then
  swift build -c release --product BoundaryBridge
  swift build -c release --product BridgeIcon
fi

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/cli" .build/Bridge.iconset
cp .build/release/BoundaryBridge "$app/Contents/MacOS/BoundaryBridge"
mkdir -p "$app/Contents/Resources/BridgeResources"
cp -R Sources/BridgeCore/Resources/. "$app/Contents/Resources/BridgeResources/"
.build/release/BridgeIcon .build/Bridge.iconset
iconutil -c icns .build/Bridge.iconset -o "$app/Contents/Resources/AppIcon.icns"

# Optional CLI bundling from the already installed Boundary Desktop. Preserve
# HashiCorp's binary and accompanying license unchanged.
cli_source="${BRIDGE_CLI_SOURCE:-/Applications/Boundary.app/Contents/Resources/cli/boundary}"
if [[ -x "$cli_source" ]]; then
  license_source="$(dirname "$cli_source")/LICENSE.txt"
  if [[ ! -f "$license_source" ]]; then
    echo "Missing CLI LICENSE.txt beside $cli_source; cannot bundle it." >&2
    exit 1
  fi
  cp "$cli_source" "$app/Contents/Resources/cli/boundary"
  cp "$license_source" "$app/Contents/Resources/cli/LICENSE.txt"
fi

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>BoundaryBridge</string>
  <key>CFBundleIdentifier</key><string>local.boundary.bridge</string>
  <key>CFBundleName</key><string>Boundary Bridge</string>
  <key>CFBundleDisplayName</key><string>Boundary Bridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1.2</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Boundary Bridge. Boundary CLI is provided by HashiCorp / IBM under its included license.</string>
</dict></plist>
PLIST

codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Built: $PWD/$app"
echo "Local ad-hoc build: downloaded copies will trigger Gatekeeper. Use scripts/package-release.sh for distribution."

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="SpotifyNotch"
APP_BUNDLE="${ROOT_DIR}/build/${APP_NAME}.app"

cd "${ROOT_DIR}"
swift build -c release

BIN_PATH="${ROOT_DIR}/.build/release/${APP_NAME}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>SpotifyNotch</string>
    <key>CFBundleDisplayName</key>
    <string>SpotifyNotch</string>
    <key>CFBundleIdentifier</key>
    <string>local.hzh.SpotifyNotch</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleExecutable</key>
    <string>SpotifyNotch</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>SpotifyNotch 需要读取并控制本地 Spotify 桌面端以同步曲目信息与歌词。</string>
</dict>
</plist>
EOF

echo "Built: ${APP_BUNDLE}"

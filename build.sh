#!/bin/zsh
# Builds MeetingChatScroller.app (universal) and installs it to ~/Applications.
# Pass --no-install to only build into ./build.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/MeetingChatScroller.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -O -target arm64-apple-macos13 main.swift -o build/arm64
swiftc -O -target x86_64-apple-macos13 main.swift -o build/x86_64
lipo -create build/arm64 build/x86_64 -output "$APP/Contents/MacOS/MeetingChatScroller"
rm build/arm64 build/x86_64

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MeetingChatScroller</string>
  <key>CFBundleIdentifier</key><string>com.andrewlandini.meetingchatscroller</string>
  <key>CFBundleExecutable</key><string>MeetingChatScroller</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"

[[ "${1:-}" == "--no-install" ]] && exit 0

mkdir -p ~/Applications
rm -rf ~/Applications/MeetingChatScroller.app
cp -R "$APP" ~/Applications/
echo "Installed to ~/Applications/MeetingChatScroller.app"

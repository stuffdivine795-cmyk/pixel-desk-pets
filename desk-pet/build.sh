#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"

APP="$PWD/DeskPet.app"
mkdir -p "$APP/Contents/MacOS"
# Keep the compiler's writable module cache inside this workspace.
mkdir -p "$PWD/.build/module-cache"
cat PixelDrawing.swift Play.swift Meeting.swift Landing.swift UserPlay.swift DeskPet.swift > "$PWD/.build/main.swift"
swiftc -D DESK_PET -O -swift-version 5 -target arm64-apple-macosx18.0 \
  -module-cache-path "$PWD/.build/module-cache" \
  "$PWD/.build/main.swift" -o "$APP/Contents/MacOS/DeskPet"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>DeskPet</string>
  <key>CFBundleIdentifier</key><string>local.deskpet.app</string>
  <key>CFBundleName</key><string>DeskPet</string>
  <key>CFBundleDisplayName</key><string>小橘桌宠</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>18.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
# Sign the assembled bundle, including its Info.plist (local ad-hoc signature).
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"

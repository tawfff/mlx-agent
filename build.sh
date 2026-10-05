#!/bin/bash
# Builds "mlx-agent.app" and installs it in /Applications. Run: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
node check.js
swiftc tools.swift tools-check.swift -o /tmp/mlx-agent-toolcheck && /tmp/mlx-agent-toolcheck

APP="build/mlx-agent.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset

swiftc -O -swift-version 5 main.swift tools.swift -o "$APP/Contents/MacOS/mlx-agent"
swift pixel-art.swift sheet "$APP/Contents/Resources/sprite-sheet.png"
cp index.html lib.js marked.umd.js "$APP/Contents/Resources/"

swift pixel-art.swift icon build/icon.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s * 2)) $((s * 2)) build/icon.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>mlx-agent</string>
  <key>CFBundleDisplayName</key><string>mlx-agent</string>
  <key>CFBundleIdentifier</key><string>io.github.tawfff.mlx-agent</string>
  <key>CFBundleExecutable</key><string>mlx-agent</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP"
[ -n "${NO_INSTALL:-}" ] && { echo "Built $APP"; exit 0; }
rm -rf "/Applications/mlx-agent.app"
cp -R "$APP" /Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/mlx-agent.app"
echo "Installed /Applications/mlx-agent.app"

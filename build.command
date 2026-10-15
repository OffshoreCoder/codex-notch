#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
if ! xcrun --find swiftc >/dev/null 2>&1; then
  print -u2 'Нужны уже установленные Apple Command Line Tools (Swift). Ничего не скачиваю.'
  exit 1
fi
project_root="$PWD"
app_path="$project_root/CodexNotch.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$project_root/.build/module-cache"
xcrun swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$project_root/.build/module-cache" \
  -framework AppKit -framework Foundation -framework Carbon -framework IOKit -framework CoreAudio -lsqlite3 \
  "$project_root"/Sources/*.swift -o "$app_path/Contents/MacOS/CodexNotch"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>CodexNotch</string>
  <key>CFBundleIdentifier</key><string>local.codex.notch</string>
  <key>CFBundleName</key><string>CodexNotch</string>
  <key>CFBundleDisplayName</key><string>Codex Notch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.1</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xcrun swiftc -O -module-cache-path "$project_root/.build/module-cache" -framework AppKit \
  "$project_root/Tools/GenerateIcon.swift" -o "$project_root/.build/generate-icon"
"$project_root/.build/generate-icon" "$app_path/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - --identifier local.codex.notch "$app_path"
print "Собрано: $app_path"

#!/bin/zsh
# Builds a release binary and wraps it in an .app bundle with icon.
# Rename the product by changing APP_NAME (and BUNDLE_ID to match).
set -e
cd "$(dirname "$0")"

APP_NAME="TokenFlow"
BUNDLE_ID="com.wasakunset.tokenflow"

swift build -c release

APP="$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/AIUsageTracker "$APP/Contents/MacOS/$APP_NAME"

# App icon (dual usage rings), regenerated on every build.
ICONSET=".build/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
EOF

# Ad-hoc sign so Keychain "Always Allow" sticks across launches.
codesign --force --sign - "$APP"

echo "Built: $PWD/$APP"
echo "Launch it with:  open \"$APP\""

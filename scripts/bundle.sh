#!/bin/zsh
# Builds Aerial Rotator.app and dist/AerialRotator-<version>.zip.
#   --install   also copy the app to /Applications (quitting a running copy first)
# ARCHS="arm64 x86_64" for a universal build; Apple silicon only by default.
# The .app is kept in a *.noindex folder so Spotlight and Launchpad don't list a second copy.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-2.0.0}"
STAGE=".build/bundle.noindex"
APP="$STAGE/Aerial Rotator.app"
ARCH_FLAGS=()
for arch in ${=ARCHS:-arm64}; do ARCH_FLAGS+=(--arch "$arch"); done

swift build -c release "${ARCH_FLAGS[@]}"
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/AerialRotator"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AerialRotator"
cp Assets/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>AerialRotator</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>io.github.alexlegoshin.aerial-rotator</string>
  <key>CFBundleName</key><string>Aerial Rotator</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

# Ad-hoc signature: required to run on Apple silicon; not a Developer ID.
codesign --force --sign - "$APP"

mkdir -p dist
rm -f "dist/AerialRotator-$VERSION.zip"
ditto -c -k --keepParent "$APP" "dist/AerialRotator-$VERSION.zip"
echo "Built $APP and dist/AerialRotator-$VERSION.zip"

if [[ "${1:-}" == "--install" ]]; then
  pkill -f "Aerial Rotator.app/Contents/MacOS/AerialRotator" && sleep 1 || true
  ditto "$APP" "/Applications/Aerial Rotator.app"
  open "/Applications/Aerial Rotator.app"
  echo "Installed /Applications/Aerial Rotator.app"
fi

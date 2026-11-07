#!/bin/bash
# Buduje iDisk.app z binarki SwiftPM i włącza ikonę.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$ROOT/iDisk"
BIN="$PROJ/.build/release/iDisk"
ICON_SRC="$ROOT/idiskicon.png"
APP="$ROOT/iDisk.app"

echo "==> wersjonowanie (+0.0.1, po 0.0.15 → 0.1.0)"
VER_FILE="$PROJ/VERSION"
VER="$(cat "$VER_FILE" 2>/dev/null || echo 0.0.0)"
IFS='.' read -r MAJ MIN PAT <<< "$VER"
PAT=$((PAT+1))
if [ "$PAT" -gt 15 ]; then PAT=0; MIN=$((MIN+1)); fi
if [ "$MIN" -gt 15 ]; then MIN=0; MAJ=$((MAJ+1)); fi
VER_NEW="$MAJ.$MIN.$PAT"
echo "$VER_NEW" > "$VER_FILE"
echo "  wersja: $VER_NEW"

echo "==> swift build"
swift build -c release --package-path "$PROJ"

echo "==> ikona → AppIcon.icns"
WORK="$(mktemp -d)"
ICONSET="$WORK/AppIcon.iconset"
SQUARE="$WORK/square.png"
mkdir -p "$ICONSET"
sips -c 505 505 "$ICON_SRC" --out "$SQUARE" >/dev/null
sips --setProperty format png "$SQUARE" >/dev/null

i=0
for pair in "icon_16x16.png:16" "icon_16x16@2x.png:32" \
            "icon_32x32.png:32" "icon_32x32@2x.png:64" \
            "icon_128x128.png:128" "icon_128x128@2x.png:256" \
            "icon_256x256.png:256" "icon_256x256@2x.png:512" \
            "icon_512x512.png:512" "icon_512x512@2x.png:1024"; do
  name="${pair%%:*}"
  size="${pair##*:}"
  tmp="$WORK/tmp_$i.png"
  sips -z "$size" "$size" "$SQUARE" --out "$tmp" >/dev/null
  mv "$tmp" "$ICONSET/$name"
  i=$((i+1))
done
iconutil -c icns "$ICONSET" -o "$PROJ/AppIcon.icns"

echo "==> budowa struktury iDisk.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>pl</string>
	<key>CFBundleExecutable</key>
	<string>iDisk</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>local.idisk.tools</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>iDisk</string>
	<key>CFBundleDisplayName</key>
	<string>iDisk</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VER_NEW}</string>
	<key>CFBundleVersion</key>
	<string>${VER_NEW}</string>
	<key>CFBundleGetInfoString</key>
	<string>iDisk ${VER_NEW} — Created by Kamil Gorecki</string>
	<key>NSHumanReadableCopyright</key>
	<string>Created by Kamil Gorecki</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
</dict>
</plist>
PLIST

cp "$BIN" "$APP/Contents/MacOS/iDisk"
cp "$PROJ/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

chmod +x "$APP/Contents/MacOS/iDisk"

echo "==> podpis (stabilna tożsamość)"
SIGN_ID="iDisk Code Signing"
if security find-identity -p codesigning -v 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --sign "$SIGN_ID" --timestamp=none "$APP/Contents/MacOS/iDisk"
  codesign --force --sign "$SIGN_ID" --identifier local.idisk.tools --timestamp=none "$APP"
  echo "  podpisano: $SIGN_ID"
else
  codesign --force --sign - --identifier local.idisk.tools "$APP"
  echo "  UWAGA: podpisano ad-hoc — włącz stabilny podpis: ./sign-cert.sh"
fi

echo "==> gotowe: $APP"
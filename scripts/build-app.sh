#!/bin/zsh
# Builds Koban.app with plain swiftc — no Xcode / XcodeGen needed (Command Line Tools suffice).
#
#   scripts/build-app.sh            release build  -> build/app/Koban.app
#   scripts/build-app.sh --debug    debug build (enables the KOBAN_SNAPSHOT developer hooks)
#   OUT=/some/dir scripts/build-app.sh   custom output folder
#   VERSION=1.2.0 BUILD_NUMBER=42 scripts/build-app.sh   version in Info.plist (release pipeline)
#   ARCHS="arm64 x86_64" scripts/build-app.sh            universal binary (default: this Mac's arch)
#
# Mirrors project.yml: app sources + KobanCore compiled into one module, linked against sqlite3.
set -euo pipefail
ROOT=${0:A:h:h}
OUT=${OUT:-$ROOT/build/app}
APP=$OUT/Koban.app
FLAGS=(-O)
[[ "${1:-}" == "--debug" ]] && FLAGS=(-D DEBUG -Onone)
VERSION=${VERSION:-0.1.0}
BUILD_NUMBER=${BUILD_NUMBER:-1}
ARCH_LIST=(${=ARCHS:-$(uname -m)})

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SOURCES=($(find "$ROOT/Koban" "$ROOT/KobanKit/Sources/KobanCore" -name '*.swift'))
SLICES=()
for ARCH in $ARCH_LIST; do
  swiftc $FLAGS -target $ARCH-apple-macos14.0 -sdk "$(xcrun --show-sdk-path)" \
    -module-name Koban -parse-as-library \
    $SOURCES -lsqlite3 -o "$OUT/Koban-$ARCH"
  SLICES+=("$OUT/Koban-$ARCH")
done
lipo -create $SLICES -output "$APP/Contents/MacOS/Koban"
rm -f $SLICES
cp -R "$ROOT/Koban/Resources/." "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Koban</string>
<key>CFBundleIdentifier</key><string>com.roland-matuz.koban</string>
<key>CFBundleName</key><string>Koban</string>
<key>CFBundleDisplayName</key><string>Koban</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.finance</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSFaceIDUsageDescription</key><string>Unlock your Koban vault with Touch ID.</string>
<key>NSHumanReadableCopyright</key><string>© 2026 Roland Matuz</string>
</dict></plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"

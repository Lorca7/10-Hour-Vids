#!/bin/bash
# Builds "10 Hour Vids.app" into ./dist (and a .zip of it).
#
# Needs only Apple's free Command Line Tools:   xcode-select --install
#
#   ./scripts/build-app.sh               # universal app (Apple Silicon + Intel)
#   ARCHS=arm64 ./scripts/build-app.sh   # just this Mac's architecture (faster)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="10 Hour Vids"
EXEC="TenHourVids"
OUT="dist"
APP="$OUT/$APP_NAME.app"

if [ -z "${ARCHS:-}" ]; then
    ARCHS="arm64 x86_64"
fi

binaries=()
for arch in $ARCHS; do
    echo "==> Building for $arch"
    swift build -c release --arch "$arch"
    binaries+=(".build/$arch-apple-macosx/release/$EXEC")
done

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/$EXEC"
cp Packaging/Info.plist "$APP/Contents/Info.plist"

# App icon from Packaging/AppIcon.png
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Packaging/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double Packaging/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so macOS will run it on this Mac.
codesign --force --deep --sign - "$APP"

(cd "$OUT" && rm -f TenHourVids-macOS.zip && ditto -c -k --keepParent "$APP_NAME.app" TenHourVids-macOS.zip)

echo
echo "Done: $APP"
echo "Drag it into /Applications, or run:  open \"$APP\""

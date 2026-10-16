#!/usr/bin/env bash
# Builds SonyBar.app into ./build.
#   ./build.sh            build for this Mac
#   ./build.sh --install  also copy to /Applications
#   ./build.sh --release  universal (Apple Silicon + Intel) build, zipped into ./dist
set -euo pipefail
cd "$(dirname "$0")"

APP=build/SonyBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ "${1:-}" == "--release" ]]; then
  bins=()
  for arch in arm64 x86_64; do
    swift build -c release --triple "$arch-apple-macosx14.0"
    bins+=(".build/$arch-apple-macosx/release/SonyBar")
  done
  lipo -create "${bins[@]}" -output "$APP/Contents/MacOS/SonyBar"
else
  swift build -c release
  cp "$(swift build -c release --show-bin-path)/SonyBar" "$APP/Contents/MacOS/SonyBar"
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built $APP"

case "${1:-}" in
  --install)
    rm -rf /Applications/SonyBar.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/SonyBar.app"
    ;;
  --release)
    version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
    mkdir -p dist
    zip="dist/SonyBar-$version.zip"
    rm -f "$zip"
    ditto -c -k --keepParent "$APP" "$zip"
    echo "Packaged $zip ($(lipo -archs "$APP/Contents/MacOS/SonyBar"))"
    shasum -a 256 "$zip"
    ;;
esac

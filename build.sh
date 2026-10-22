#!/usr/bin/env bash
# Builds SonyBar.app into ./build.
#   ./build.sh            build for this Mac
#   ./build.sh --install  also copy to /Applications
#   ./build.sh --release  universal (Apple Silicon + Intel) build, zipped into ./dist
set -euo pipefail
cd "$(dirname "$0")"

# Command Line Tools can ship an SDK whose SwiftUI macros (@State) it has no plugin for.
# If the default SDK can't build SwiftUI, fall back to the newest installed SDK that can.
if [[ -z "${SDKROOT:-}" ]]; then
  probe=$(mktemp -d)
  printf 'import SwiftUI\nstruct V: View { @State var x = 0; var body: some View { EmptyView() } }\n' > "$probe/v.swift"
  if ! swiftc -typecheck "$probe/v.swift" 2>/dev/null; then
    for sdk in $(ls -d "$(xcode-select -p)"/SDKs/MacOSX[0-9]*.*.sdk 2>/dev/null | sort -rV); do
      if SDKROOT="$sdk" swiftc -typecheck "$probe/v.swift" 2>/dev/null; then
        export SDKROOT="$sdk"
        echo "Using $(basename "$sdk") (default SDK can't build SwiftUI with these tools)"
        break
      fi
    done
  fi
  rm -rf "$probe"
fi

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

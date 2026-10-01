#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
sdk="${NAMEGUARD_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
[[ -d "$sdk" ]] || sdk="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p .build/desktop-release dist
release_stage="$(mktemp -d "$PWD/.build/desktop-release/stage.XXXXXX")"
package="$release_stage/NameGuard-Desktop"
app="$package/NameGuard Desktop.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
for cpu in arm64 x86_64; do
  xcrun swiftc -O -sdk "$sdk" -target "$cpu-apple-macosx13.0" \
    Sources/NameGuard/Core.swift Sources/NameGuard/Watcher.swift Sources/NameGuardMenu/*.swift Sources/NameGuardCLI/main.swift \
    -o "$release_stage/nameguard-$cpu"
done
xcrun lipo -create "$release_stage/nameguard-arm64" "$release_stage/nameguard-x86_64" -output "$app/Contents/MacOS/nameguard"
cp app-info.plist "$app/Contents/Info.plist"
cp resources/update.sh "$app/Contents/Resources/update.sh"
plutil -replace CFBundleIdentifier -string local.nameguard.desktop.app "$app/Contents/Info.plist"
plutil -replace CFBundleName -string 'NameGuard Desktop' "$app/Contents/Info.plist"
plutil -insert LSMinimumSystemVersion -string 13.0 "$app/Contents/Info.plist"
for file in distribution/desktop/*; do cp "$file" "$package/"; done
chmod 755 "$package/설치.command" "$package/상태확인.command" "$package/자동실행해제.command"
codesign --force --sign - --identifier local.nameguard.desktop.app "$app"
codesign --verify --deep --strict "$app"
/usr/bin/ditto -c -k --keepParent "$package" "$PWD/dist/NameGuard-Desktop.zip"
echo "배포 파일: $PWD/dist/NameGuard-Desktop.zip"
echo "검증용 폴더: $package"

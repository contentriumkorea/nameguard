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
export MACOSX_DEPLOYMENT_TARGET=13.0
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  cargo build --release --locked --target "$target"
  cp "target/$target/release/nameguard" "$release_stage/nameguard-$target"
done
xcrun lipo -create "$release_stage/nameguard-aarch64-apple-darwin" "$release_stage/nameguard-x86_64-apple-darwin" -output "$app/Contents/MacOS/nameguard"
cp app-info.plist "$app/Contents/Info.plist"
cp resources/update.sh "$app/Contents/Resources/update.sh"
plutil -replace CFBundleIdentifier -string local.nameguard.desktop.app "$app/Contents/Info.plist"
plutil -replace CFBundleName -string 'NameGuard Desktop' "$app/Contents/Info.plist"
plutil -insert LSMinimumSystemVersion -string 13.0 "$app/Contents/Info.plist"
for file in distribution/desktop/*; do cp "$file" "$package/"; done
python3 scripts/dependency-notices.py "$package/THIRD-PARTY-NOTICES.txt"
chmod 755 "$package/설치.command" "$package/상태확인.command" "$package/자동실행해제.command"
codesign --force --sign - --identifier local.nameguard.desktop.app "$app"
codesign --verify --deep --strict "$app"
/usr/bin/ditto -c -k --keepParent "$package" "$PWD/dist/NameGuard-Desktop.zip"
echo "배포 파일: $PWD/dist/NameGuard-Desktop.zip"
echo "검증용 폴더: $package"

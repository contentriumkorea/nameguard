#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
# Prefer the compatible SDK on this Mac without changing xcode-select globally.
sdk="${NAMEGUARD_SDK:-}"
if [[ -z "$sdk" ]]; then
  if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
  else
    sdk="$(xcrun --sdk macosx --show-sdk-path)"
  fi
fi
xcrun swiftc -O -sdk "$sdk" Sources/NameGuard/Core.swift Sources/NameGuard/Watcher.swift Sources/NameGuardMenu/*.swift Sources/NameGuardCLI/main.swift -o .build/nameguard
echo "Built: $PWD/.build/nameguard"

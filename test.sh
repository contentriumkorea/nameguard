#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash build.sh
sdk="${NAMEGUARD_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
[[ -d "$sdk" ]] || sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -sdk "$sdk" Sources/NameGuard/Core.swift Tests/Smoke.swift -o .build/smoke
.build/smoke
xcrun swiftc -sdk "$sdk" Sources/NameGuardMenu/MenuState.swift Tests/MenuSmoke.swift -o .build/menu-smoke
.build/menu-smoke
xcrun swiftc -sdk "$sdk" Sources/NameGuard/Core.swift Sources/NameGuard/Watcher.swift Sources/NameGuardMenu/MenuState.swift Sources/NameGuardMenu/MenuSession.swift Tests/MenuLifecycle.swift -o .build/menu-lifecycle
.build/menu-lifecycle "$PWD/.build/nameguard"
/usr/bin/python3 Tests/integration.py

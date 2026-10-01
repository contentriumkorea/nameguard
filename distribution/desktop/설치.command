#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
install_root="$HOME"
staging=false
if [[ "${1:-}" == --stage && -n "${2:-}" && "${2:-}" == /* && "${2:-}" != / ]]; then
  install_root="$2"
  staging=true
elif [[ $# -ne 0 ]]; then
  echo '알 수 없는 설치 옵션입니다.'; exit 2
fi
trap 'echo "설치를 완료하지 못했습니다. 위 오류 내용을 확인해 주세요."' ERR
payload="$PWD/NameGuard Desktop.app"
app="$install_root/Applications/NameGuard Desktop.app"
state="$install_root/Library/Application Support/NameGuardDesktop"
agent="$install_root/Library/LaunchAgents/local.nameguard.desktop.agent.plist"
label=local.nameguard.desktop.agent

if [[ ! -x "$payload/Contents/MacOS/nameguard" ]]; then
  echo 'ZIP을 먼저 풀고 설치.command와 NameGuard Desktop.app을 같은 폴더에 두세요.'; exit 1
fi
bundle_id=local.nameguard.desktop.app
if [[ -f "$install_root/Library/LaunchAgents/local.nameguard.agent.plist" ]] ||
   [[ -d "$install_root/Applications/NameGuard.app" && -f "$install_root/Library/Application Support/NameGuard/config.json" && ! -d "$install_root/Applications/NameGuard Desktop.app" ]]; then
  # Upgrade the existing edition in place, keeping Desktop + Dropbox and exclusions.
  app="$install_root/Applications/NameGuard.app"
  state="$install_root/Library/Application Support/NameGuard"
  agent="$install_root/Library/LaunchAgents/local.nameguard.agent.plist"
  label=local.nameguard.agent
  bundle_id=local.nameguard.app
  if [[ -f "$install_root/Library/LaunchAgents/local.nameguard.desktop.agent.plist" ]]; then
    echo '기존 버전과 Desktop 버전이 모두 설치되어 있습니다. 하나의 자동 실행을 먼저 해제해 주세요.'; exit 1
  fi
fi
if [[ -e "$app" ]]; then
  existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$existing_id" == "$bundle_id" ]] || { echo '같은 이름의 다른 앱이 있습니다. 설치를 중단합니다.'; exit 1; }
fi

echo 'NameGuard를 설치합니다. 상단 바에서 감시 폴더를 선택할 수 있습니다.'
mkdir -p "$install_root/Applications" "$state" "$install_root/Library/LaunchAgents"
chmod 700 "$state"
if ! $staging; then launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true; fi
/usr/bin/ditto "$payload" "$app"
if [[ "$bundle_id" == local.nameguard.app ]]; then
  plutil -replace CFBundleIdentifier -string "$bundle_id" "$app/Contents/Info.plist"
  codesign --force --sign - --identifier "$bundle_id" "$app"
fi
if [[ ! -f "$state/config.json" ]]; then
  cp "$PWD/desktop-config.json" "$state/config.json"
  if [[ "$bundle_id" == local.nameguard.app ]]; then
    plutil -remove roots "$state/config.json"
  else
    plutil -replace roots -json '[]' "$state/config.json"
    plutil -insert roots.0 -string "$install_root/Desktop" "$state/config.json"
  fi
  plutil -convert json "$state/config.json"
else
  cp "$state/config.json" "$state/config-backup-$(date +%Y%m%d-%H%M%S).json"
fi

plutil -create xml1 "$agent"
plutil -insert Label -string "$label" "$agent"
plutil -insert ProgramArguments -json '[]' "$agent"
plutil -insert ProgramArguments.0 -string "$app/Contents/MacOS/nameguard" "$agent"
plutil -insert ProgramArguments.1 -string '--menu' "$agent"
plutil -insert ProgramArguments.2 -string '--state-dir' "$agent"
plutil -insert ProgramArguments.3 -string "$state" "$agent"
plutil -insert RunAtLoad -bool true "$agent"
plutil -insert KeepAlive -json '{"SuccessfulExit":false}' "$agent"
plutil -insert ThrottleInterval -integer 60 "$agent"
plutil -insert ProcessType -string Interactive "$agent"
plutil -insert LowPriorityIO -bool true "$agent"
plutil -insert StandardOutPath -string "$state/launchd.stdout.log" "$agent"
plutil -insert StandardErrorPath -string "$state/launchd.stderr.log" "$agent"
chmod 644 "$agent"
plutil -lint "$agent"
printf '{"enabled":true}\n' > "$state/login.json"

if $staging; then
  echo "설치 파일 준비 완료 (자동 실행 등록 없음): $install_root"
  exit 0
fi
# Exercise the copied executable so Gatekeeper can present any required approval.
if ! "$app/Contents/MacOS/nameguard" --help; then
  echo 'macOS가 실행을 차단했을 수 있습니다. 동봉된 먼저 읽어주세요.txt의 보안 안내를 확인한 후 설치를 다시 실행하세요.'
  exit 1
fi
launchctl enable "gui/$(id -u)/$label"
launchctl bootstrap "gui/$(id -u)" "$agent"
launchctl kickstart "gui/$(id -u)/$label"
echo ''
echo '설치 및 자동 실행 등록을 완료했습니다. 이 터미널 창은 닫아도 됩니다.'
echo 'Desktop 접근 허용 요청이 뜨면 허용해 주세요. 앞으로 로그인할 때 자동 실행됩니다.'
echo '처음에는 바탕화면의 기존 항목을 순차 검사하므로 시간이 걸릴 수 있습니다.'
echo '상단 바의 NameGuard 아이콘을 눌러 상태 확인, 폴더 선택, 일시중지를 할 수 있습니다.'

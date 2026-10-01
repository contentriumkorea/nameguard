#!/bin/bash
set -euo pipefail
state="$HOME/Library/Application Support/NameGuardDesktop"
agent="$HOME/Library/LaunchAgents/local.nameguard.desktop.agent.plist"
label=local.nameguard.desktop.agent
if [[ ! -f "$agent" && -f "$HOME/Library/LaunchAgents/local.nameguard.agent.plist" ]]; then
  state="$HOME/Library/Application Support/NameGuard"
  agent="$HOME/Library/LaunchAgents/local.nameguard.agent.plist"
  label=local.nameguard.agent
fi
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
if [[ -f "$agent" ]]; then
  mkdir -p "$state"
  mv "$agent" "$state/disabled-agent-$(date +%Y%m%d-%H%M%S).plist"
fi
echo '감시와 로그인 자동 실행을 해제했습니다.'
echo '앱·설정·로그는 보존했습니다. 이미 변환한 파일명도 그대로 유지됩니다.'
echo '다시 사용하려면 설치.command를 실행하세요.'

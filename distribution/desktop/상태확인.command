#!/bin/bash
set -uo pipefail
state="$HOME/Library/Application Support/NameGuardDesktop"
if launchctl print "gui/$(id -u)/local.nameguard.desktop.agent" 2>/dev/null | /usr/bin/grep -q 'state = running'; then
  echo '감시 프로그램: 실행 중'
else
  echo '감시 프로그램: 실행 중이 아닙니다. 설치 또는 macOS 실행 권한을 확인해 주세요.'
fi
if [[ -f "$state/status.json" ]]; then
  echo '아래 값은 마지막 기록입니다. 현재 시각과 updated 시각도 확인하세요.'
  plutil -p "$state/status.json"
  echo ''
  echo 'renamedThisRun = 이번 실행의 변환 횟수 / pending = 변환 대기'
  echo 'scanDirectoriesRemaining = 검사 대기 폴더 / errorsThisRun = 누적 오류 횟수'
  echo 'paused = 편집 프로그램 실행 등으로 보류된 사유'
else
  echo '상태 기록이 아직 없습니다. 설치 직후라면 잠시 후 다시 확인해 주세요.'
fi
echo ''
echo "로그 위치: $state/events.jsonl"
if [[ -s "$state/launchd.stderr.log" ]]; then
  echo '최근 실행 오류:'
  tail -n 8 "$state/launchd.stderr.log"
fi

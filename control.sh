#!/bin/bash
set -euo pipefail
label=local.nameguard.agent
target="gui/$(id -u)/$label"
agent="$HOME/Library/LaunchAgents/$label.plist"
state="$HOME/Library/Application Support/NameGuard"
case "${1:-status}" in
  status)
    launchctl print "$target" | sed -n '1,38p'
    [[ ! -f "$state/status.json" ]] || /usr/bin/plutil -p "$state/status.json"
    ;;
  stop) launchctl bootout "$target" ;;
  start) launchctl bootstrap "gui/$(id -u)" "$agent" ;;
  restart) launchctl kickstart -k "$target" ;;
  logs) tail -n 30 "$state/events.jsonl" ;;
  uninstall)
    launchctl bootout "$target" 2>/dev/null || true
    if [[ -f "$agent" ]]; then mv "$agent" "$state/disabled-agent-$(date +%Y%m%d-%H%M%S).plist"; fi
    echo "Automatic startup disabled. App, configuration and logs retained in $state and ~/Applications/NameGuard.app."
    ;;
  *) echo 'Usage: bash control.sh status|stop|start|restart|logs|uninstall'; exit 2 ;;
esac

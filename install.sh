#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash build.sh
app="$HOME/Applications/NameGuard.app"
state="$HOME/Library/Application Support/NameGuard"
agent="$HOME/Library/LaunchAgents/local.nameguard.agent.plist"
label=local.nameguard.agent
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$state" "$HOME/Library/LaunchAgents"
chmod 700 "$state"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
attempts=0
while launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [[ "$attempts" -lt 150 ]] || { echo 'Previous NameGuard is still stopping. Retry shortly.'; exit 1; }
  sleep 0.1
done
cp .build/nameguard "$app/Contents/MacOS/nameguard"
cp app-info.plist "$app/Contents/Info.plist"
cp resources/update.sh "$app/Contents/Resources/update.sh"
codesign --force --sign - --identifier local.nameguard.app "$app"
if [[ ! -f "$state/config.json" ]]; then
  cp config.example.json "$state/config.json"
  plutil -insert roots -json '[]' "$state/config.json"
  plutil -insert roots.0 -string "$HOME/Desktop" "$state/config.json"
  plutil -convert json "$state/config.json"
fi
plutil -create xml1 "$agent"
plutil -insert Label -string "$label" "$agent"
plutil -insert ProgramArguments -json "[]" "$agent"
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
launchctl enable "gui/$(id -u)/$label"
launchctl bootstrap "gui/$(id -u)" "$agent"
echo "Installed and started: $label"
echo "Status: $state/status.json"

#!/bin/bash
set -euo pipefail
[[ $# == 8 ]] || exit 2
old_pid=$1; target=$2; candidate=$3; workspace=$4; token=$5; version=$6; state=$7; ticks=$8
[[ "$old_pid" =~ ^[0-9]+$ && "$ticks" =~ ^[0-9]+$ && "$ticks" -ge 1 && "$ticks" -le 1200 ]] || exit 2
[[ "$token" =~ ^[0-9a-f-]{36}$ && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
[[ "$target" == /*.app && "$state" == /* && "$workspace" == "$state/updates/$token" ]] || exit 2
[[ "$candidate" == "$target.nameguard-update-$token.app" && -d "$target" && -d "$candidate" ]] || exit 2
backup="$target.nameguard-backup-$token"
[[ ! -e "$backup" ]] || exit 2
health="$workspace/health"
count=0
while kill -0 "$old_pid" 2>/dev/null; do
  count=$((count + 1)); [[ "$count" -lt 300 ]] || exit 1
  sleep 0.1
done
new_pid=''
rollback() {
  trap - EXIT HUP INT TERM
  if [[ -n "$new_pid" ]]; then
    kill "$new_pid" 2>/dev/null || true
    for ((i=0; i<50; i++)); do kill -0 "$new_pid" 2>/dev/null || break; sleep 0.1; done
    kill -KILL "$new_pid" 2>/dev/null || true
    wait "$new_pid" 2>/dev/null || true
  fi
  if [[ -e "$target" ]]; then /bin/mv "$target" "$workspace/failed.app" || exit 2; fi
  /bin/mv "$backup" "$target" || exit 2
  printf 'rollback\n' > "$workspace/status"
  "$target/Contents/MacOS/nameguard" --menu --state-dir "$state" >> "$workspace/app.log" 2>&1 &
  printf '%s' "$!" > "$workspace/app.pid"
  exit 1
}
/bin/mv "$target" "$backup"
trap rollback EXIT HUP INT TERM
/bin/mv "$candidate" "$target"
"$target/Contents/MacOS/nameguard" --menu --state-dir "$state" --update-health "$health" --update-version "$version" >> "$workspace/app.log" 2>&1 &
new_pid=$!
printf '%s' "$new_pid" > "$workspace/app.pid"
for ((i=0; i<ticks; i++)); do
  if [[ -f "$health" && "$(cat "$health")" == "$version" ]] && kill -0 "$new_pid" 2>/dev/null; then
    trap - EXIT HUP INT TERM
    # Keep the previous app in this private workspace for recovery.
    /bin/mv "$backup" "$workspace/previous.app"
    printf 'installed\n' > "$workspace/status"
    exit 0
  fi
  kill -0 "$new_pid" 2>/dev/null || exit 1
  sleep 0.1
done
exit 1

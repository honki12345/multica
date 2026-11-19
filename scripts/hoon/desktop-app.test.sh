#!/usr/bin/env bash
# Tests for scripts/hoon/desktop-app.sh with stubbed macOS tools and fake apps.
#   bash scripts/hoon/desktop-app.test.sh
# Stub bodies and check expressions are single-quoted on purpose: they expand
# when the stub runs or when check evals them.
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/desktop-app.sh"
fail=0
pass() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }
check() { if eval "$2"; then pass "$1"; else bad "$1"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/desktop-app-test.XXXXXX")"
trap '/bin/rm -rf "$T"' EXIT
mkdir -p "$T/stub" "$T/Applications" "$T/home" "$T/userdata" "$T/caches"

# State files the stubs read: whether the app runs, whether ShipIt runs, the
# daemon's active task count.
export STUB_STATE="$T/state" STUB_LOG="$T/calls.log"
mkdir -p "$STUB_STATE"

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/stub/$1"; chmod +x "$T/stub/$1"; }
stub plutil 'f="${@: -1}"; sed -n "s/^version=//p" "$f"'
stub pgrep 'echo "pgrep $*" >> "$STUB_LOG"
case "$*" in
  *ShipIt*) [[ -f "$STUB_STATE/shipit" ]] ;;
  *"daemon start"*) [[ -f "$STUB_STATE/app" ]] && echo "1 /x/resources/bin/multica daemon start --foreground --profile desktop-test" ;;
  *) [[ -f "$STUB_STATE/app" ]] ;;
esac'
stub pkill 'echo "pkill $*" >> "$STUB_LOG"; /bin/rm -f "$STUB_STATE/shipit"'
stub launchctl 'echo "launchctl $*" >> "$STUB_LOG"'
stub osascript 'echo "osascript" >> "$STUB_LOG"; [[ -f "$STUB_STATE/stuck" ]] || /bin/rm -f "$STUB_STATE/app"'
stub open 'echo "open $*" >> "$STUB_LOG"; touch "$STUB_STATE/app"'
stub xattr 'echo "xattr $*" >> "$STUB_LOG"'
stub ditto 'cp -R "$1" "$2"'
stub sleep 'exit 0'

# fake_app <dir> <app version> <cli version> <feed owner>
fake_app() {
  mkdir -p "$1/Contents/Resources/app.asar.unpacked/resources/bin"
  printf 'version=%s\n' "$2" > "$1/Contents/Info.plist"
  printf 'owner: %s\nrepo: multica\nprovider: github\n' "$4" > "$1/Contents/Resources/app-update.yml"
  cat > "$1/Contents/Resources/app.asar.unpacked/resources/bin/multica" <<EOF
#!/usr/bin/env bash
case "\$1" in
  version) echo "multica $3 (commit: x)" ;;
  daemon) printf '{"active_task_count": %s, "cli_version": "%s", "status": "running"}\n' "\$(cat "\$STUB_STATE/active" 2>/dev/null || echo 0)" "$3" ;;
esac
EOF
  chmod +x "$1/Contents/Resources/app.asar.unpacked/resources/bin/multica"
}

export PATH="$T/stub:$PATH"
export MULTICA_DESKTOP_APP="$T/Applications/Multica.app" \
  MULTICA_DESKTOP_HOME="$T/home/desktop" \
  MULTICA_DESKTOP_BACKUP_DIR="$T/home/Applications-backup" \
  MULTICA_DESKTOP_USER_DATA="$T/userdata" \
  MULTICA_DESKTOP_CACHES="$T/caches" \
  MULTICA_DESKTOP_QUIT_WAIT=2 MULTICA_DESKTOP_DAEMON_WAIT=10
NEW="$MULTICA_DESKTOP_HOME/apps/0.11.0-hoon.1/Multica.app"
APP="$MULTICA_DESKTOP_APP"

reset_machine() {
  /bin/rm -rf "${T:?}/Applications"/* "${T:?}/home" "${T:?}/userdata"/* "${T:?}/caches"/* "${STUB_STATE:?}"/* "$STUB_LOG"
  fake_app "$APP" 0.10.0 0.10.0 multica-ai
  fake_app "$NEW" 0.11.0-hoon.1 0.11.0-hoon.1 honki12345
  mkdir -p "$T/caches/ai.multica.desktop.ShipIt/update.x/Multica.app" "$T/caches/@multicadesktop-updater/pending"
  touch "$STUB_STATE/app" "$STUB_STATE/shipit"
}

# shellcheck source=/dev/null
source "$SCRIPT"

# --- version resolution ---
check "version from hoon tag" '[[ "$(resolve_version v0.11.0-hoon.1)" == 0.11.0-hoon.1 ]]'
check "bare X.Y.Z rejected" '! (resolve_version 0.11.0) 2>/dev/null'

# --- bundle checks ---
reset_machine
check "fork bundle passes" '(check_bundle "$NEW" 0.11.0-hoon.1) 2>/dev/null'
check "official bundle rejected" '! (check_bundle "$APP" 0.10.0-hoon.1) 2>/dev/null'
fake_app "$T/wrong-cli.app" 0.11.0-hoon.1 0.10.0 honki12345
check "bundle with official CLI rejected" '! (check_bundle "$T/wrong-cli.app" 0.11.0-hoon.1) 2>/dev/null'
fake_app "$T/wrong-feed.app" 0.11.0-hoon.1 0.11.0-hoon.1 multica-ai
check "bundle with official feed rejected" '! (check_bundle "$T/wrong-feed.app" 0.11.0-hoon.1) 2>/dev/null'

# --- install ---
reset_machine
echo 2 > "$STUB_STATE/active"
check "install refuses while the daemon is busy" '! (cmd_install 0.11.0-hoon.1 --no-open) 2>/dev/null'
check "busy refusal leaves the official app" '[[ "$(app_version "$APP")" == 0.10.0 ]]'
/bin/rm -f "$STUB_STATE/active"

reset_machine
touch "$STUB_STATE/stuck"
check "install stops when the app will not quit" '! (cmd_install 0.11.0-hoon.1 --no-open) 2>/dev/null'
check "stuck quit leaves the official app in place" '[[ "$(app_version "$APP")" == 0.10.0 ]]'

reset_machine
( cmd_install 0.11.0-hoon.1 ) 2>/dev/null
# shellcheck disable=SC2034  # read inside check eval strings
backup="$(cat "$MULTICA_DESKTOP_HOME/last-backup")"
check "install puts the fork app in place" '[[ "$(app_version "$APP")" == 0.11.0-hoon.1 ]]'
check "official app kept as Multica-0.10.0-<ts>.app" '[[ "$backup" == "$MULTICA_DESKTOP_BACKUP_DIR"/Multica-0.10.0-*.app && "$(app_version "$backup")" == 0.10.0 ]]'
check "ShipIt job removed before quitting the app" 'grep -n . "$STUB_LOG" | awk "/launchctl remove/ {l=NR} /osascript/ {o=NR} END {exit !(l && o && l < o)}"'
check "staged official update moved out of the caches" '[[ ! -e "$T/caches/ai.multica.desktop.ShipIt" && ! -e "$T/caches/@multicadesktop-updater" ]]'
check "staged update kept next to the backup" '[[ -d "${backup%.app}-updater-cache/ai.multica.desktop.ShipIt" ]]'
check "automatic updates written off" 'grep -q "\"automaticUpdates\": false" "$T/userdata/updater-preferences.json"'
check "quarantine cleared" 'grep -q "xattr -dr com.apple.quarantine" "$STUB_LOG"'
check "app reopened" 'grep -q "^open " "$STUB_LOG"'
check "verify passes on the installed fork app" '(cmd_verify 0.11.0-hoon.1) 2>/dev/null'

touch "$STUB_STATE/shipit"
check "verify fails while ShipIt runs" '! (cmd_verify 0.11.0-hoon.1) 2>/dev/null'
/bin/rm -f "$STUB_STATE/shipit"

# --- rollback ---
( cmd_rollback --no-open ) 2>/dev/null
check "rollback restores the official app" '[[ "$(app_version "$APP")" == 0.10.0 ]]'
check "rollback keeps the fork app aside" 'ls -d "$MULTICA_DESKTOP_BACKUP_DIR"/Multica-0.11.0-hoon.1-*-rolledback.app >/dev/null'
check "rollback keeps automatic updates off" 'grep -q "\"automaticUpdates\": false" "$T/userdata/updater-preferences.json"'
check "second rollback has nothing to restore" '! (cmd_rollback --no-open) 2>/dev/null'

exit "$fail"

#!/usr/bin/env bash
# Tests for scripts/hoon/desktop-app.sh with stubbed macOS tools and fake apps.
#   bash scripts/hoon/desktop-app.test.sh
# Every command runs as its own `bash desktop-app.sh ...` process, so set -e
# behaves as it does for a real run. Stub bodies and check expressions are
# single-quoted on purpose: they expand when the stub runs or when check evals.
# shellcheck disable=SC2016,SC2034,SC2329  # used inside check eval strings
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/desktop-app.sh"
fail=0
pass() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }
check() { if eval "$2"; then pass "$1"; else bad "$1"; fi; }
run() { bash "$SCRIPT" "$@" >>"$T/run.log" 2>&1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/desktop-app-test.XXXXXX")"
trap 'chmod -R u+w "$T" 2>/dev/null; /bin/rm -rf "$T"' EXIT
mkdir -p "$T/stub" "$T/Applications" "$T/userdata" "$T/caches"
export STUB_STATE="$T/state" STUB_LOG="$T/calls.log"
mkdir -p "$STUB_STATE"

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/stub/$1"; chmod +x "$T/stub/$1"; }
# plutil -extract <key> raw -o - <file|->, over JSON files.
stub plutil 'key="$2"; src="${@: -1}"; python3 -c "
import json,sys
src=sys.argv[2]
d=json.load(sys.stdin if src==\"-\" else open(src))
v=d[sys.argv[1]]
print(str(v).lower() if isinstance(v,bool) else v)" "$key" "$src"'
stub pgrep 'echo "pgrep $*" >> "$STUB_LOG"
case "$*" in
  *ShipIt*) [[ -f "$STUB_STATE/shipit" ]] ;;
  *"daemon start"*) [[ -f "$STUB_STATE/daemon" ]] && echo "1 /x/resources/bin/multica daemon start --foreground --profile desktop-test" ;;
  *) [[ -f "$STUB_STATE/app" ]] ;;
esac'
stub pkill 'echo "pkill $*" >> "$STUB_LOG"; [[ -f "$STUB_STATE/shipit-sticky" ]] || /bin/rm -f "$STUB_STATE/shipit"'
stub launchctl 'echo "launchctl $*" >> "$STUB_LOG"'
stub osascript 'echo "osascript" >> "$STUB_LOG"
[[ -f "$STUB_STATE/stuck" ]] && exit 0
/bin/rm -f "$STUB_STATE/app" "$STUB_STATE/daemon"
[[ -f "$STUB_STATE/rearm" ]] && touch "$STUB_STATE/shipit"
exit 0'
stub open 'echo "open $*" >> "$STUB_LOG"; touch "$STUB_STATE/app" "$STUB_STATE/daemon"'
stub xattr 'echo "xattr $*" >> "$STUB_LOG"'
stub ditto '[[ -f "$STUB_STATE/ditto-fail" ]] && exit 42; cp -R "$1" "$2"'
stub sleep 'exit 0'

# fake_app <dir> <app version> <cli version> <feed owner>
fake_app() {
  mkdir -p "$1/Contents/Resources/app.asar.unpacked/resources/bin"
  printf '{"CFBundleShortVersionString": "%s"}\n' "$2" > "$1/Contents/Info.plist"
  printf 'owner: %s\nrepo: multica\nprovider: github\n' "$4" > "$1/Contents/Resources/app-update.yml"
  cat > "$1/Contents/Resources/app.asar.unpacked/resources/bin/multica" <<EOF
#!/usr/bin/env bash
case "\$1" in
  version) echo "multica $3 (commit: x)" ;;
  daemon)
    [[ -f "\$STUB_STATE/status-fail" ]] && { echo "connection refused" >&2; exit 1; }
    printf '{"active_task_count": %s, "cli_version": "%s", "status": "running"}\n' "\$(cat "\$STUB_STATE/active" 2>/dev/null || echo 0)" "$3" ;;
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
  MULTICA_DESKTOP_QUIT_WAIT=2 MULTICA_DESKTOP_DAEMON_WAIT=10 MULTICA_DESKTOP_SHIPIT_WAIT=2
NEW="$MULTICA_DESKTOP_HOME/apps/0.11.0-hoon.1/Multica.app"
APP="$MULTICA_DESKTOP_APP"
PREFS="$T/userdata/updater-preferences.json"
ver() { plutil -extract CFBundleShortVersionString raw -o - "$1/Contents/Info.plist" 2>/dev/null; }

reset_machine() {
  chmod -R u+w "$T/caches" 2>/dev/null || true
  /bin/rm -rf "${T:?}/Applications"/* "${T:?}/Applications"/.Multica* "${T:?}/home" "${T:?}/userdata"/* \
    "${T:?}/caches"/* "${STUB_STATE:?}"/* "$STUB_LOG"
  fake_app "$APP" 0.10.0 0.10.0 multica-ai
  fake_app "$NEW" 0.11.0-hoon.1 0.11.0-hoon.1 honki12345
  mkdir -p "$T/caches/ai.multica.desktop.ShipIt/update.x/Multica.app" "$T/caches/@multicadesktop-updater/pending"
  touch "$STUB_STATE/app" "$STUB_STATE/daemon" "$STUB_STATE/shipit"
}
unchanged() { [[ "$(ver "$APP")" == 0.10.0 && ! -e "$MULTICA_DESKTOP_HOME/last-backup" ]]; }

# --- arguments and bundle checks ---
reset_machine
check "bare X.Y.Z rejected" '! run install 0.11.0'
fake_app "$T/wrong-cli.app" 0.11.0-hoon.2 0.10.0 honki12345
fake_app "$T/wrong-feed.app" 0.11.0-hoon.3 0.11.0-hoon.3 multica-ai
mkdir -p "$MULTICA_DESKTOP_HOME/apps/0.11.0-hoon.2" "$MULTICA_DESKTOP_HOME/apps/0.11.0-hoon.3"
cp -R "$T/wrong-cli.app" "$MULTICA_DESKTOP_HOME/apps/0.11.0-hoon.2/Multica.app"
cp -R "$T/wrong-feed.app" "$MULTICA_DESKTOP_HOME/apps/0.11.0-hoon.3/Multica.app"
check "bundle with official CLI rejected" '! run install 0.11.0-hoon.2 && unchanged'
check "bundle with official feed rejected" '! run install 0.11.0-hoon.3 && unchanged'

# --- install refusals leave the official app in place ---
reset_machine; echo 2 > "$STUB_STATE/active"
check "refuses while the daemon is busy" '! run install 0.11.0-hoon.1 --no-open && unchanged'

reset_machine; touch "$STUB_STATE/status-fail"
check "refuses when the daemon status cannot be read" '! run install 0.11.0-hoon.1 --no-open && unchanged'

reset_machine; touch "$STUB_STATE/stuck"
check "stops when the app will not quit" '! run install 0.11.0-hoon.1 --no-open && unchanged'

reset_machine; touch "$STUB_STATE/shipit-sticky"
check "stops before quitting when ShipIt will not stop" '! run install 0.11.0-hoon.1 --no-open && unchanged && ! grep -q osascript "$STUB_LOG"'

reset_machine; chmod a-w "$T/caches"
check "stops before quitting when the staged update cannot be moved" '! run install 0.11.0-hoon.1 --no-open && unchanged && ! grep -q osascript "$STUB_LOG"'
chmod u+w "$T/caches"

reset_machine; touch "$STUB_STATE/rearm"
check "stops when quitting re-arms ShipIt" '! run install 0.11.0-hoon.1 --no-open && unchanged'

reset_machine; touch "$STUB_STATE/ditto-fail"
check "failed copy keeps the official app installed" '! run install 0.11.0-hoon.1 --no-open && unchanged && ! ls -d "$T/Applications"/.Multica.app.staged-* >/dev/null 2>&1'

reset_machine; /bin/rm -f "$STUB_STATE/daemon"
check "installs when no app daemon is running" 'run install 0.11.0-hoon.1 --no-open && [[ "$(ver "$APP")" == 0.11.0-hoon.1 ]]'

# --- install ---
reset_machine
run install 0.11.0-hoon.1
backup="$(cat "$MULTICA_DESKTOP_HOME/last-backup")"
check "fork app in place" '[[ "$(ver "$APP")" == 0.11.0-hoon.1 ]]'
check "official app kept as Multica-0.10.0-<ts>.app" '[[ "$backup" == "$MULTICA_DESKTOP_BACKUP_DIR"/Multica-0.10.0-*.app && "$(ver "$backup")" == 0.10.0 ]]'
check "ShipIt removed before the app quits" 'awk "/launchctl remove/ {l=NR} /osascript/ {o=NR} END {exit !(l && o && l < o)}" "$STUB_LOG"'
check "staged update kept next to the backup" '[[ -d "${backup%.app}-updater-cache/ai.multica.desktop.ShipIt" && -d "${backup%.app}-updater-cache/@multicadesktop-updater" ]]'
check "automatic updates off" '[[ "$(plutil -extract automaticUpdates raw -o - "$PREFS")" == false ]]'
check "quarantine cleared" 'grep -q "xattr -dr com.apple.quarantine" "$STUB_LOG"'
check "app reopened" 'grep -q "^open " "$STUB_LOG"'
check "verify passes" 'run verify 0.11.0-hoon.1'
touch "$STUB_STATE/shipit"
check "verify fails while ShipIt runs" '! run verify 0.11.0-hoon.1'
/bin/rm -f "$STUB_STATE/shipit"

# --- rollback ---
printf '{"automaticUpdates": true}\n' > "$PREFS"
check "rollback restores the official app" 'run rollback --no-open && [[ "$(ver "$APP")" == 0.10.0 ]]'
check "rollback turns automatic updates off" '[[ "$(plutil -extract automaticUpdates raw -o - "$PREFS")" == false ]]'
check "rollback keeps the fork app aside" 'ls -d "$MULTICA_DESKTOP_BACKUP_DIR"/Multica-0.11.0-hoon.1-*-rolledback.app >/dev/null'
check "second rollback has nothing to restore" '! run rollback --no-open && [[ "$(ver "$APP")" == 0.10.0 ]]'

reset_machine; run install 0.11.0-hoon.1 --no-open; /bin/rm -f "$PREFS"
check "rollback with no preference file still writes it off" 'run rollback --no-open && [[ "$(plutil -extract automaticUpdates raw -o - "$PREFS")" == false ]]'

exit "$fail"

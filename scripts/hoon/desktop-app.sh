#!/usr/bin/env bash
# Fork-only tool that builds and swaps the Multica desktop app on a Mac that
# runs it (calabii-macmini). See FORK.md "Desktop app (Mac mini)".
#
#   scripts/hoon/desktop-app.sh build    <vX.Y.Z-hoon.N>   # clone the tag, package an ad-hoc signed arm64 app
#   scripts/hoon/desktop-app.sh install  <X.Y.Z-hoon.N> [--force] [--no-open]
#   scripts/hoon/desktop-app.sh verify   <X.Y.Z-hoon.N>
#   scripts/hoon/desktop-app.sh rollback [--no-open]
#   scripts/hoon/desktop-app.sh status
#
# install stops the official updater (ShipIt) before quitting the app, because
# a downloaded official update is installed the moment the app quits. The old
# app moves to ~/Applications-backup; the data folder
# (~/Library/Application Support/Multica) and ~/.multica are never touched
# except for updater-preferences.json.
set -euo pipefail

APP="${MULTICA_DESKTOP_APP:-/Applications/Multica.app}"
DESKTOP_HOME="${MULTICA_DESKTOP_HOME:-$HOME/.local/share/multica-desktop}"
BACKUP_DIR="${MULTICA_DESKTOP_BACKUP_DIR:-$HOME/Applications-backup}"
USER_DATA="${MULTICA_DESKTOP_USER_DATA:-$HOME/Library/Application Support/Multica}"
CACHES="${MULTICA_DESKTOP_CACHES:-$HOME/Library/Caches}"
REPO_URL="${MULTICA_DESKTOP_REPO:-https://github.com/honki12345/multica.git}"
QUIT_WAIT="${MULTICA_DESKTOP_QUIT_WAIT:-60}"
DAEMON_WAIT="${MULTICA_DESKTOP_DAEMON_WAIT:-120}"
VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+-hoon\.[0-9]+$'
FEED_OWNER=honki12345
SHIPIT_LABEL=ai.multica.desktop.ShipIt
APP_PROC='Multica.app/Contents/MacOS/Multica$'

log() { printf '[desktop] %s\n' "$*" >&2; }
die() { printf '[desktop] ERROR: %s\n' "$*" >&2; exit 1; }
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"; }

resolve_version() {
  local v="${1#v}"
  [[ -n "$v" ]] || die "missing version"
  # A bare X.Y.Z would make the bundled daemon treat itself as an official
  # release (server/internal/cli/update.go IsReleaseVersion).
  [[ "$v" =~ $VERSION_RE ]] || die "version '$v' must look like X.Y.Z-hoon.N"
  echo "$v"
}

bundled_cli() { echo "$1/Contents/Resources/app.asar.unpacked/resources/bin/multica"; }
app_version() { plutil -extract CFBundleShortVersionString raw -o - "$1/Contents/Info.plist" 2>/dev/null || true; }
cli_version() { "$1" version 2>/dev/null | head -1 | awk '{print $2}'; }
feed_owner() { awk -F': *' '$1=="owner" { print $2 }' "$1/Contents/Resources/app-update.yml" 2>/dev/null || true; }
json_field() { sed -n "s/.*\"$1\": *\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" | head -1; }

# The bundle must carry the fork version in both the app and its CLI, and an
# update feed that can only ever point at the fork.
check_bundle() {
  local app="$1" v="$2" got
  [[ -d "$app" ]] || die "no app at $app"
  got="$(app_version "$app")"
  [[ "$got" == "$v" ]] || die "$app version is '$got', expected $v"
  got="$(cli_version "$(bundled_cli "$app")")"
  [[ "$got" == "$v" ]] || die "$app bundled CLI is '$got', expected $v"
  got="$(feed_owner "$app")"
  [[ -z "$got" || "$got" == "$FEED_OWNER" ]] || die "$app update feed owner is '$got', expected $FEED_OWNER"
}

# The Mac mini has no global pnpm; corepack provides the version pinned in
# package.json without an interactive download prompt.
pnpm_cmd() {
  if command -v pnpm >/dev/null 2>&1; then echo pnpm; else echo "corepack pnpm"; fi
}
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

cmd_build() {
  local tag="${1:-}"
  [[ -n "$tag" ]] || die "usage: build <vX.Y.Z-hoon.N>"
  local v; v="$(resolve_version "$tag")"
  tag="v$v"
  local src="$DESKTOP_HOME/src/$v" out="$DESKTOP_HOME/apps/$v/Multica.app"
  if [[ ! -d "$src/.git" ]]; then
    log "cloning $REPO_URL $tag -> $src"
    mkdir -p "$(dirname "$src")"
    git clone --quiet --depth 1 --branch "$tag" "$REPO_URL" "$src"
  fi
  local described
  described="$(git -C "$src" describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null || true)"
  [[ "$described" == "$tag" ]] || die "$src is at '$described', expected $tag (remove it to re-clone)"
  [[ -z "$(git -C "$src" status --porcelain)" ]] || die "$src has local changes; the version would gain -dirty"

  local pnpm; pnpm="$(pnpm_cmd)"
  log "installing dependencies ($pnpm)"
  (cd "$src" && $pnpm install --frozen-lockfile --prefer-offline)
  log "packaging (ad-hoc signature, no notarization, no publish)"
  (cd "$src/apps/desktop" && CSC_IDENTITY_AUTO_DISCOVERY=false $pnpm package -- --mac --arm64 --dir --publish never)

  local built="$src/apps/desktop/dist/mac-arm64/Multica.app"
  check_bundle "$built" "$v"
  /bin/rm -rf "$out"
  mkdir -p "$(dirname "$out")"
  ditto "$built" "$out"
  log "built $out"
  echo "$out"
}

running_app() { pgrep -f "$APP_PROC" >/dev/null 2>&1; }

daemon_profile() {
  pgrep -fl 'resources/bin/multica daemon start' 2>/dev/null \
    | sed -n 's/.*--profile \([^ ]*\).*/\1/p' | head -1
}

daemon_status_json() {
  local app="$1" profile="$2"
  "$(bundled_cli "$app")" daemon status --profile "$profile" --output json 2>/dev/null || true
}

# A downloaded official update is installed by ShipIt as soon as the app quits,
# so the updater goes first and its staged bundle leaves the cache.
stop_official_updater() {
  local keep="$1"
  launchctl remove "$SHIPIT_LABEL" >/dev/null 2>&1 || true
  pkill -f "ShipIt $SHIPIT_LABEL" >/dev/null 2>&1 || true
  mkdir -p "$keep"
  for d in "$CACHES/$SHIPIT_LABEL" "$CACHES/@multicadesktop-updater"; do
    [[ -e "$d" ]] && mv "$d" "$keep/" && log "moved $d -> $keep/"
  done
  return 0
}

quit_app() {
  running_app || return 0
  osascript -e 'tell application "Multica" to quit' >/dev/null 2>&1 || true
  local i
  for ((i = 0; i < QUIT_WAIT; i++)); do
    running_app || return 0
    sleep 1
  done
  die "Multica is still running (a quit dialog may be open); the app was not replaced"
}

disable_automatic_updates() {
  local prefs="$USER_DATA/updater-preferences.json" ts="$1"
  mkdir -p "$USER_DATA"
  [[ -f "$prefs" ]] && cp -p "$prefs" "$prefs.bak-$ts"
  printf '{\n  "automaticUpdates": false\n}\n' > "$prefs"
}

cmd_install() {
  local version="" force=0 open_app=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1; shift ;;
      --no-open) open_app=0; shift ;;
      -*) die "unknown install flag $1" ;;
      *) version="$1"; shift ;;
    esac
  done
  local v; v="$(resolve_version "$version")"
  local new="$DESKTOP_HOME/apps/$v/Multica.app"
  check_bundle "$new" "$v"

  local profile; profile="$(daemon_profile)"
  if [[ -n "$profile" && -d "$APP" ]]; then
    local active
    active="$(daemon_status_json "$APP" "$profile" | json_field active_task_count)"
    if [[ "${active:-0}" != "0" && "$force" != 1 ]]; then
      die "daemon $profile has $active active task(s); retry when idle or pass --force"
    fi
  fi

  local ts old_version backup
  ts="$(date +%Y%m%d%H%M%S)"
  old_version="$(app_version "$APP")"
  backup="$BACKUP_DIR/Multica-${old_version:-unknown}-$ts.app"
  mkdir -p "$BACKUP_DIR" "$DESKTOP_HOME"

  stop_official_updater "$BACKUP_DIR/Multica-${old_version:-unknown}-$ts-updater-cache"
  quit_app
  if [[ -d "$APP" ]]; then
    mv "$APP" "$backup"
    echo "$backup" > "$DESKTOP_HOME/last-backup"
    log "kept $APP (${old_version:-unknown}) at $backup"
  fi
  ditto "$new" "$APP"
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  disable_automatic_updates "$ts"
  log "installed $v at $APP"
  [[ "$open_app" == 1 ]] && open "$APP"
  return 0
}

cmd_verify() {
  local v; v="$(resolve_version "${1:-}")"
  check_bundle "$APP" "$v"
  log "app $(app_version "$APP"), bundled CLI $(cli_version "$(bundled_cli "$APP")"), feed $(feed_owner "$APP")"
  grep -q '"automaticUpdates": *false' "$USER_DATA/updater-preferences.json" 2>/dev/null \
    || die "automatic updates are not off in $USER_DATA/updater-preferences.json"
  if pgrep -f "ShipIt $SHIPIT_LABEL" >/dev/null 2>&1; then die "the official updater (ShipIt) is running"; fi
  running_app || die "Multica is not running"

  local i profile json got=""
  for ((i = 0; i < DAEMON_WAIT; i += 5)); do
    profile="$(daemon_profile)"
    if [[ -n "$profile" ]]; then
      json="$(daemon_status_json "$APP" "$profile")"
      got="$(printf '%s' "$json" | json_field cli_version)"
      [[ "$got" == "$v" ]] && break
    fi
    sleep 5
  done
  [[ "$got" == "$v" ]] || die "app daemon reports '${got:-none}', expected $v"
  log "daemon $profile cli_version $got, status $(printf '%s' "$json" | json_field status)"
  log "verify: OK"
}

cmd_rollback() {
  local open_app=1
  [[ "${1:-}" == "--no-open" ]] && open_app=0
  local backup
  backup="$(cat "$DESKTOP_HOME/last-backup" 2>/dev/null || true)"
  [[ -n "$backup" && -d "$backup" ]] || die "no backup recorded in $DESKTOP_HOME/last-backup"
  local ts current
  ts="$(date +%Y%m%d%H%M%S)"
  current="$(app_version "$APP")"
  stop_official_updater "$BACKUP_DIR/Multica-${current:-unknown}-$ts-updater-cache"
  quit_app
  [[ -d "$APP" ]] && mv "$APP" "$BACKUP_DIR/Multica-${current:-unknown}-$ts-rolledback.app"
  mv "$backup" "$APP"
  : > "$DESKTOP_HOME/last-backup"
  log "restored $(app_version "$APP") from $backup; automatic updates stay off"
  [[ "$open_app" == 1 ]] && open "$APP"
  return 0
}

cmd_status() {
  log "app $(app_version "$APP") feed $(feed_owner "$APP") bundled CLI $(cli_version "$(bundled_cli "$APP")")"
  log "updater prefs $(tr -d ' \n' < "$USER_DATA/updater-preferences.json" 2>/dev/null || echo missing)"
  log "ShipIt $(pgrep -f "ShipIt $SHIPIT_LABEL" >/dev/null 2>&1 && echo running || echo stopped)"
  local profile; profile="$(daemon_profile)"
  if [[ -n "$profile" ]]; then
    log "daemon $profile cli_version $(daemon_status_json "$APP" "$profile" | json_field cli_version)"
  else
    log "daemon not running"
  fi
  log "last backup $(cat "$DESKTOP_HOME/last-backup" 2>/dev/null || echo none)"
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    build) cmd_build "$@" ;;
    install) cmd_install "$@" ;;
    verify) cmd_verify "$@" ;;
    rollback) cmd_rollback "$@" ;;
    status) cmd_status ;;
    -h|--help|help|"") usage ;;
    *) die "unknown command $cmd (see --help)" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

#!/usr/bin/env bash
# Fork-only release tool for the honki12345/multica self-host on this Mac.
#
# Builds the backend image, the web image and the CLI/daemon binary from one
# git ref, swaps them into the running self-host, verifies the result, and
# rolls the swap back. See FORK.md "Deploy and rollback".
#
#   scripts/hoon/release.sh build    <ref> [--version X.Y.Z-hoon.N] [--only cli,backend,web]
#   scripts/hoon/release.sh deploy   <X.Y.Z-hoon.N>
#   scripts/hoon/release.sh release  <ref> [--version X.Y.Z-hoon.N]   # build + deploy
#   scripts/hoon/release.sh verify   [X.Y.Z-hoon.N]
#   scripts/hoon/release.sh rollback
#   scripts/hoon/release.sh status
#
# Versions: <ref> is normally a tag vX.Y.Z-hoon.N. The CLI reports X.Y.Z-hoon.N
# (-X main.version); images are tagged vX.Y.Z-hoon.N and the backend/web carry
# the same v-prefixed string, matching upstream's vX.Y.Z image tags.
#
# Secrets: the script never prints .env contents; it only reads and prints the
# three image keys and the public app URL.
set -euo pipefail

SELFHOST_DIR="${MULTICA_SELFHOST_DIR:-$HOME/.local/share/multica-selfhost}"
COMPOSE_FILE="${MULTICA_COMPOSE_FILE:-$SELFHOST_DIR/docker-compose.selfhost.yml}"
COMPOSE_PROJECT="${MULTICA_COMPOSE_PROJECT:-multica}"
COMPOSE_SERVICES="${MULTICA_COMPOSE_SERVICES:-backend frontend}"
RESIDENT_BIN="${MULTICA_RESIDENT_BIN:-$HOME/.local/share/multica-resident/bin/multica}"
RELEASE_HOME="${MULTICA_HOON_RELEASE_HOME:-$HOME/.local/share/multica-resident/releases}"
BACKEND_IMAGE="${MULTICA_HOON_BACKEND_IMAGE:-multica-backend-hoon}"
WEB_IMAGE="${MULTICA_HOON_WEB_IMAGE:-multica-web-hoon}"
WAIT_SECONDS="${MULTICA_HOON_WAIT_SECONDS:-120}"
IMAGE_KEYS=(MULTICA_IMAGE_TAG MULTICA_BACKEND_IMAGE MULTICA_WEB_IMAGE)
VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+-hoon\.[0-9]+$'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="$SELFHOST_DIR/.env"
DEPLOYS_DIR="$RELEASE_HOME/deploys"

log() { printf '[release] %s\n' "$*" >&2; }
die() { printf '[release] ERROR: %s\n' "$*" >&2; exit 1; }

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"; }

# Reads one key from .env without echoing anything else.
env_get() {
  local key="$1" file="${2:-$ENV_FILE}"
  awk -v k="$key" 'index($0, k"=")==1 { v=substr($0, length(k)+2) } END { if (v!="") print v }' "$file"
}

frontend_port() { local p; p="$(env_get FRONTEND_PORT)"; echo "${p:-3000}"; }
backend_port() {
  local p
  for k in BACKEND_PORT API_PORT SERVER_PORT PORT; do
    p="$(env_get "$k")"
    [[ -n "$p" ]] && { echo "$p"; return; }
  done
  echo 8080
}
public_url() { local u="${MULTICA_PUBLIC_URL:-$(env_get MULTICA_APP_URL)}"; echo "${u%/}"; }

compose() { docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" "$@"; }

# ---------- version / ref ----------

resolve_version() {
  local ref="$1" explicit="$2" v=""
  if [[ -n "$explicit" ]]; then
    v="${explicit#v}"
  elif [[ "${ref#v}" =~ $VERSION_RE ]]; then
    v="${ref#v}"
  else
    local tag
    tag="$(git -C "$REPO_ROOT" describe --tags --exact-match "$ref" 2>/dev/null || true)"
    [[ "${tag#v}" =~ $VERSION_RE ]] && v="${tag#v}"
  fi
  [[ -n "$v" ]] || die "cannot derive a version from '$ref'; pass --version X.Y.Z-hoon.N"
  # A bare X.Y.Z looks like an official release to the daemon's self-update
  # (server/internal/cli/update.go IsReleaseVersion) and would be overwritten.
  [[ "$v" =~ $VERSION_RE ]] || die "version '$v' must look like X.Y.Z-hoon.N"
  echo "$v"
}

# ---------- build ----------

cmd_build() {
  local ref="" version_arg="" only="cli,backend,web"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) version_arg="$2"; shift 2 ;;
      --only) only="$2"; shift 2 ;;
      -*) die "unknown build flag $1" ;;
      *) [[ -z "$ref" ]] || die "build takes one ref"; ref="$1"; shift ;;
    esac
  done
  [[ -n "$ref" ]] || die "usage: build <ref> [--version X.Y.Z-hoon.N] [--only cli,backend,web]"

  local sha short v out src date
  sha="$(git -C "$REPO_ROOT" rev-parse --verify "$ref^{commit}")" || die "unknown ref $ref"
  short="$(git -C "$REPO_ROOT" rev-parse --short=9 "$sha")"
  v="$(resolve_version "$ref" "$version_arg")"
  out="$RELEASE_HOME/$v"
  src="$out/src"
  date="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  if [[ -f "$out/build.env" ]]; then
    local prev_sha; prev_sha="$(env_get SHA "$out/build.env")"
    [[ "$prev_sha" == "$sha" ]] || die "$v was already built from $prev_sha, not $sha; bump N instead of reusing a version"
  fi

  # Export the committed tree only, so uncommitted files never reach a release.
  mkdir -p "$out"
  if [[ ! -f "$src/.export-sha" || "$(cat "$src/.export-sha")" != "$sha" ]]; then
    log "exporting $ref ($short) to $src"
    rm -rf "$src"; mkdir -p "$src"
    git -C "$REPO_ROOT" archive --format=tar "$sha" | tar -x -C "$src"
    echo "$sha" > "$src/.export-sha"
  fi

  if [[ ",$only," == *",cli,"* ]]; then
    log "building CLI $v"
    (cd "$src/server" && CGO_ENABLED="${CGO_ENABLED:-1}" go build \
      -ldflags "-X main.version=$v -X main.commit=$short -X main.buildCommit=$sha -X main.date=$date" \
      -o "$out/multica.tmp" ./cmd/multica)
    mv -f "$out/multica.tmp" "$out/multica"
    "$out/multica" version | head -1 >&2
  fi
  if [[ ",$only," == *",backend,"* ]]; then
    log "building $BACKEND_IMAGE:v$v"
    docker build -f "$src/Dockerfile" \
      --build-arg "VERSION=v$v" --build-arg "COMMIT=$short" --build-arg "DATE=$date" \
      -t "$BACKEND_IMAGE:v$v" "$src" >&2
  fi
  if [[ ",$only," == *",web,"* ]]; then
    log "building $WEB_IMAGE:v$v"
    docker build -f "$src/Dockerfile.web" \
      --build-arg "NEXT_PUBLIC_APP_VERSION=v$v" \
      -t "$WEB_IMAGE:v$v" "$src" >&2
  fi

  printf 'VERSION=%s\nREF=%s\nSHA=%s\nCOMMIT=%s\nBACKEND_IMAGE=%s\nWEB_IMAGE=%s\n' \
    "$v" "$ref" "$sha" "$short" "$BACKEND_IMAGE" "$WEB_IMAGE" > "$out/build.env"
  log "build done: $v ($short) in $out"
  echo "$v"
}

# ---------- .env swap ----------

# Writes a copy of $1 to $2 with only the image keys replaced.
write_env_with_images() {
  local src="$1" dst="$2" tag="$3" backend="$4" web="$5"
  awk -v tag="$tag" -v be="$backend" -v we="$web" '
    BEGIN { seen["MULTICA_IMAGE_TAG"]=0; seen["MULTICA_BACKEND_IMAGE"]=0; seen["MULTICA_WEB_IMAGE"]=0 }
    index($0,"MULTICA_IMAGE_TAG=")==1     { print "MULTICA_IMAGE_TAG=" tag; seen["MULTICA_IMAGE_TAG"]=1; next }
    index($0,"MULTICA_BACKEND_IMAGE=")==1 { print "MULTICA_BACKEND_IMAGE=" be; seen["MULTICA_BACKEND_IMAGE"]=1; next }
    index($0,"MULTICA_WEB_IMAGE=")==1     { print "MULTICA_WEB_IMAGE=" we; seen["MULTICA_WEB_IMAGE"]=1; next }
    { print }
    END {
      if (!seen["MULTICA_IMAGE_TAG"])     print "MULTICA_IMAGE_TAG=" tag
      if (!seen["MULTICA_BACKEND_IMAGE"]) print "MULTICA_BACKEND_IMAGE=" be
      if (!seen["MULTICA_WEB_IMAGE"])     print "MULTICA_WEB_IMAGE=" we
    }' "$src" > "$dst"
}

# Fails unless $1 and $2 differ only in the image keys.
assert_only_image_keys_changed() {
  local pattern='^(MULTICA_IMAGE_TAG|MULTICA_BACKEND_IMAGE|MULTICA_WEB_IMAGE)='
  if ! diff -q <(grep -vE "$pattern" "$1") <(grep -vE "$pattern" "$2") >/dev/null; then
    die "refusing to write .env: a non-image key would change"
  fi
}

print_image_keys() {
  local label="$1" file="$2" k
  for k in "${IMAGE_KEYS[@]}"; do log "$label $k=$(env_get "$k" "$file")"; done
}

# ---------- binary swap ----------

install_binary() {
  local new="$1" dst="$2" tmp="$2.tmp-$$"
  cp -p "$new" "$tmp"
  chmod 0755 "$tmp"
  # rename(2) keeps the running daemon on its old inode; the daemon's
  # auto-reload picks the new version up once it has no task in flight.
  mv -f "$tmp" "$dst"
}

binary_version() { "$1" version 2>/dev/null | head -1 | awk '{print $2}'; }

# ---------- deploy ----------

cmd_deploy() {
  local v="${1:-}"
  [[ -n "$v" ]] || die "usage: deploy <X.Y.Z-hoon.N>"
  v="${v#v}"
  [[ "$v" =~ $VERSION_RE ]] || die "version '$v' must look like X.Y.Z-hoon.N"
  local out="$RELEASE_HOME/$v"
  [[ -f "$out/build.env" ]] || die "no build for $v; run build first"
  [[ -x "$out/multica" ]] || die "missing $out/multica; run build --only cli"
  local be we
  be="$(env_get BACKEND_IMAGE "$out/build.env")"
  we="$(env_get WEB_IMAGE "$out/build.env")"
  docker image inspect "$be:v$v" >/dev/null 2>&1 || die "missing image $be:v$v"
  docker image inspect "$we:v$v" >/dev/null 2>&1 || die "missing image $we:v$v"
  [[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE"
  [[ "$(binary_version "$out/multica")" == "$v" ]] || die "$out/multica does not report $v"

  local ts env_bak bin_bak rec new_env
  ts="$(date '+%Y%m%d%H%M%S')"
  env_bak="$ENV_FILE.bak-$ts"
  bin_bak="$RESIDENT_BIN.bak-$ts"
  mkdir -p "$DEPLOYS_DIR"
  rec="$DEPLOYS_DIR/$ts.env"

  new_env="$ENV_FILE.new-$ts"
  write_env_with_images "$ENV_FILE" "$new_env" "v$v" "$be" "$we"
  chmod 0600 "$new_env"
  assert_only_image_keys_changed "$ENV_FILE" "$new_env"

  cp -p "$ENV_FILE" "$env_bak"
  local prev_bin_version=""
  if [[ -f "$RESIDENT_BIN" ]]; then
    cp -p "$RESIDENT_BIN" "$bin_bak"
    prev_bin_version="$(binary_version "$RESIDENT_BIN" || true)"
  fi
  printf 'TS=%s\nVERSION=%s\nENV_BACKUP=%s\nBIN_BACKUP=%s\nPREV_BIN_VERSION=%s\nPREV_IMAGE_TAG=%s\nPREV_BACKEND_IMAGE=%s\nPREV_WEB_IMAGE=%s\n' \
    "$ts" "$v" "$env_bak" "$( [[ -f "$bin_bak" ]] && echo "$bin_bak" )" "$prev_bin_version" \
    "$(env_get MULTICA_IMAGE_TAG)" "$(env_get MULTICA_BACKEND_IMAGE)" "$(env_get MULTICA_WEB_IMAGE)" > "$rec"
  log "backups: $env_bak, ${bin_bak}"
  print_image_keys "before" "$ENV_FILE"

  mv -f "$new_env" "$ENV_FILE"
  print_image_keys "after " "$ENV_FILE"

  log "recreating: $COMPOSE_SERVICES (UI drops briefly)"
  # shellcheck disable=SC2086
  compose up -d --no-deps $COMPOSE_SERVICES

  install_binary "$out/multica" "$RESIDENT_BIN"
  log "binary: $prev_bin_version -> $(binary_version "$RESIDENT_BIN")"

  if ! cmd_verify "$v"; then
    log "verification failed; run: $0 rollback"
    return 1
  fi
  log "deploy $v done (record $rec)"
}

# ---------- verify ----------

wait_http_200() {
  local url="$1" deadline=$((SECONDS + WAIT_SECONDS)) code=""
  while :; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" || true)"
    [[ "$code" == "200" ]] && { echo 200; return 0; }
    (( SECONDS >= deadline )) && { echo "${code:-000}"; return 1; }
    sleep 3
  done
}

cmd_verify() {
  local v="${1:-}" ok=0 fp bp pub code health commit cfgver binver expect_commit=""
  v="${v#v}"
  fp="$(frontend_port)"; bp="$(backend_port)"; pub="$(public_url)"
  if [[ -n "$v" && -f "$RELEASE_HOME/$v/build.env" ]]; then
    expect_commit="$(env_get COMMIT "$RELEASE_HOME/$v/build.env")"
  fi

  code="$(wait_http_200 "http://127.0.0.1:$fp/login")" || ok=1
  log "check local web   /login -> $code"
  if [[ -n "$pub" ]]; then
    code="$(wait_http_200 "$pub/login")" || ok=1
    log "check public web  $pub/login -> $code"
  else
    log "check public web  skipped (no MULTICA_APP_URL)"
  fi

  code="$(wait_http_200 "http://127.0.0.1:$bp/health")" || ok=1
  health="$(curl -s --max-time 10 "http://127.0.0.1:$bp/health" || true)"
  commit="$(printf '%s' "$health" | sed -n 's/.*"commit":"\([^"]*\)".*/\1/p')"
  log "check backend     /health -> $code commit=$commit"
  if [[ -n "$expect_commit" && "$commit" != "$expect_commit" ]]; then
    log "  backend commit mismatch (want $expect_commit)"; ok=1
  fi
  [[ "$health" == *'"status":"ok"'* ]] || ok=1

  cfgver="$(curl -s --max-time 10 "http://127.0.0.1:$bp/api/config" | sed -n 's/.*"server_version":"\([^"]*\)".*/\1/p' || true)"
  log "check backend     server_version=$cfgver"
  [[ -z "$v" || "$cfgver" == "v$v" ]] || { log "  server_version mismatch (want v$v)"; ok=1; }

  binver="$(binary_version "$RESIDENT_BIN" || true)"
  log "check binary      $("$RESIDENT_BIN" version 2>/dev/null | head -1)"
  [[ -z "$v" || "$binver" == "$v" ]] || { log "  binary version mismatch (want $v)"; ok=1; }

  log "running images:"
  docker ps --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" --format '  {{.Names}} {{.Image}} {{.Status}}' >&2 || true
  [[ $ok -eq 0 ]] && log "verify: OK" || log "verify: FAILED"
  return $ok
}

# ---------- rollback ----------

cmd_rollback() {
  local rec
  rec="$(ls -1 "$DEPLOYS_DIR"/*.env 2>/dev/null | sort | tail -1 || true)"
  [[ -n "$rec" ]] || die "no deploy record to roll back in $DEPLOYS_DIR"
  local ts v env_bak bin_bak now
  ts="$(env_get TS "$rec")"; v="$(env_get VERSION "$rec")"
  env_bak="$(env_get ENV_BACKUP "$rec")"; bin_bak="$(env_get BIN_BACKUP "$rec")"
  now="$(date '+%Y%m%d%H%M%S')"
  [[ -f "$env_bak" ]] || die "missing env backup $env_bak"
  log "rolling back deploy $ts ($v)"

  local restored_env="$ENV_FILE.restore-$now"
  cp -p "$env_bak" "$restored_env"
  assert_only_image_keys_changed "$ENV_FILE" "$restored_env"
  cp -p "$ENV_FILE" "$ENV_FILE.bak-rollback-$now"
  mv -f "$restored_env" "$ENV_FILE"
  print_image_keys "restored" "$ENV_FILE"

  # shellcheck disable=SC2086
  compose up -d --no-deps $COMPOSE_SERVICES

  if [[ -n "$bin_bak" && -f "$bin_bak" ]]; then
    install_binary "$bin_bak" "$RESIDENT_BIN"
    log "binary restored: $(binary_version "$RESIDENT_BIN")"
  else
    log "no binary backup recorded; binary left as is"
  fi
  mv -f "$rec" "${rec%.env}.rolledback"
  cmd_verify "" || { log "rollback finished but checks failed"; return 1; }
  log "rollback of $v done"
}

cmd_status() {
  [[ -f "$ENV_FILE" ]] && print_image_keys "env" "$ENV_FILE"
  log "binary $("$RESIDENT_BIN" version 2>/dev/null | head -1)"
  docker ps --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" --format '  {{.Names}} {{.Image}} {{.Status}}' >&2 || true
  local last; last="$(ls -1 "$DEPLOYS_DIR"/*.env 2>/dev/null | sort | tail -1 || true)"
  log "last deploy record: ${last:-none}"
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    build) cmd_build "$@" ;;
    deploy) cmd_deploy "$@" ;;
    release)
      local v; v="$(cmd_build "$@" | tail -1)"
      cmd_deploy "$v" ;;
    verify) cmd_verify "$@" ;;
    rollback) cmd_rollback ;;
    status) cmd_status ;;
    -h|--help|help|"") usage ;;
    *) die "unknown command $cmd (see --help)" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

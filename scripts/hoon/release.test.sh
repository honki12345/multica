#!/usr/bin/env bash
# Tests for scripts/hoon/release.sh with stubbed docker/curl and a fake binary.
#   bash scripts/hoon/release.test.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release.sh"
fail=0
pass() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }
check() { if eval "$2"; then pass "$1"; else bad "$1"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/release-test.XXXXXX")"
trap '/bin/rm -rf "$T"' EXIT

mkdir -p "$T/stub" "$T/selfhost" "$T/bin" "$T/releases/0.9.0-hoon.1"
cat > "$T/stub/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB_LOG"
exit 0
EOF
cat > "$T/stub/curl" <<'EOF'
#!/usr/bin/env bash
url="${@: -1}"
for a in "$@"; do [[ "$a" == "%{http_code}" ]] && { printf 200; exit 0; }; done
case "$url" in
  */health) printf '{"status":"ok","pid":1,"commit":"%s"}' "$STUB_COMMIT" ;;
  */api/config) printf '{"server_version":"%s"}' "$STUB_SERVER_VERSION" ;;
esac
EOF
fake_bin() { printf '#!/usr/bin/env bash\necho "multica %s (commit: x)"\n' "$1" > "$2"; chmod +x "$2"; }
chmod +x "$T/stub/docker" "$T/stub/curl"

cat > "$T/selfhost/.env" <<'EOF'
JWT_SECRET=do-not-print-me
PORT=18090
FRONTEND_PORT=13010
MULTICA_APP_URL=https://example.invalid:9330
MULTICA_IMAGE_TAG=v0.9.0
MULTICA_BACKEND_IMAGE=multica-backend-resident
MULTICA_WEB_IMAGE=multica-web-resident
EOF
touch "$T/selfhost/docker-compose.selfhost.yml"
fake_bin 0.9.0-resident.6 "$T/bin/multica"
fake_bin 0.9.0-hoon.1 "$T/releases/0.9.0-hoon.1/multica"
printf 'VERSION=0.9.0-hoon.1\nREF=v0.9.0-hoon.1\nSHA=abc\nCOMMIT=0e875a6e3\nBACKEND_IMAGE=multica-backend-hoon\nWEB_IMAGE=multica-web-hoon\n' \
  > "$T/releases/0.9.0-hoon.1/build.env"

export PATH="$T/stub:$PATH" STUB_LOG="$T/docker.log" STUB_COMMIT=0e875a6e3 STUB_SERVER_VERSION=v0.9.0-hoon.1
export MULTICA_SELFHOST_DIR="$T/selfhost" MULTICA_RESIDENT_BIN="$T/bin/multica" \
  MULTICA_HOON_RELEASE_HOME="$T/releases" MULTICA_HOON_WAIT_SECONDS=2
# shellcheck disable=SC2034  # read inside check eval strings
orig_env="$(cat "$T/selfhost/.env")"

# --- version resolution ---
# shellcheck source=/dev/null
source "$SCRIPT"
check "version from hoon tag" '[[ "$(resolve_version v0.9.0-hoon.1 "")" == 0.9.0-hoon.1 ]]'
check "explicit version wins" '[[ "$(resolve_version HEAD v0.9.0-hoon.2)" == 0.9.0-hoon.2 ]]'
check "bare X.Y.Z rejected" '! (resolve_version HEAD 0.9.0) 2>/dev/null'

# --- deploy ---
out="$(bash "$SCRIPT" deploy 0.9.0-hoon.1 2>&1)" || { echo "$out"; bad "deploy exits 0"; }
check "deploy never prints secrets" '[[ "$out" != *do-not-print-me* ]]'
check "image tag swapped" 'grep -qx "MULTICA_IMAGE_TAG=v0.9.0-hoon.1" "$T/selfhost/.env"'
check "backend image swapped" 'grep -qx "MULTICA_BACKEND_IMAGE=multica-backend-hoon" "$T/selfhost/.env"'
check "web image swapped" 'grep -qx "MULTICA_WEB_IMAGE=multica-web-hoon" "$T/selfhost/.env"'
check "non-image keys untouched" '[[ "$(grep -vE "^MULTICA_(IMAGE_TAG|BACKEND_IMAGE|WEB_IMAGE)=" "$T/selfhost/.env")" == "$(printf "%s\n" "$orig_env" | grep -vE "^MULTICA_(IMAGE_TAG|BACKEND_IMAGE|WEB_IMAGE)=")" ]]'
check ".env stays 0600" '[[ "$(stat -f %Lp "$T/selfhost/.env" 2>/dev/null || stat -c %a "$T/selfhost/.env")" == 600 ]]'
check "env backup written" 'ls "$T/selfhost"/.env.bak-* >/dev/null 2>&1'
check "binary backup written" 'ls "$T/bin"/multica.bak-* >/dev/null 2>&1'
check "binary replaced" '"$T/bin/multica" version | grep -q "0.9.0-hoon.1"'
check "only backend+frontend recreated" 'grep -q "compose -p multica -f .* up -d --no-deps backend frontend" "$T/docker.log" && ! grep -q postgres "$T/docker.log"'

# --- verify catches a wrong backend ---
STUB_COMMIT=deadbeef bash "$SCRIPT" verify 0.9.0-hoon.1 >/dev/null 2>&1 && bad "verify flags commit mismatch" || pass "verify flags commit mismatch"

# --- rollback ---
: > "$T/docker.log"
out="$(bash "$SCRIPT" rollback 2>&1)" || { echo "$out"; bad "rollback exits 0"; }
check "rollback restores .env exactly" '[[ "$(cat "$T/selfhost/.env")" == "$orig_env" ]]'
check "rollback restores binary" '"$T/bin/multica" version | grep -q "0.9.0-resident.6"'
check "rollback recreates same services" 'grep -q "up -d --no-deps backend frontend" "$T/docker.log"'
check "rollback consumes the record" '! ls "$T/releases/deploys"/*.env >/dev/null 2>&1'
bash "$SCRIPT" rollback >/dev/null 2>&1 && bad "second rollback refuses" || pass "second rollback refuses"

# --- refuses an .env change outside image keys ---
src="$T/a.env"; dst="$T/b.env"
printf 'A=1\nMULTICA_IMAGE_TAG=x\n' > "$src"; printf 'A=2\nMULTICA_IMAGE_TAG=y\n' > "$dst"
(assert_only_image_keys_changed "$src" "$dst") 2>/dev/null && bad "guard rejects non-image change" || pass "guard rejects non-image change"

exit $fail

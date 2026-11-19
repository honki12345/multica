#!/usr/bin/env bash
# Candidate stack on the remote Docker host (calabii-02), run by fork-verify.sh.
# Receives one command per invocation on stdin-free argv:
#   stack-remote.sh up <dir> <name> <db-port> <api-port> <web-port> <version> <commit>
#   stack-remote.sh down <dir> <name>
# <dir> holds src.tgz (git archive of the candidate ref) and backup.dump.
# Everything it creates is named fv-<name>-*; down removes exactly that.
set -euo pipefail

cmd="${1:?usage}"; dir="${2:?dir}"; name="${3:?name}"
net="fv-${name}-net"; pg="fv-${name}-pg"; be="fv-${name}-backend"; fe="fv-${name}-web"
vol="fv-${name}-pgdata"; bimg="fv-${name}-backend:candidate"; wimg="fv-${name}-web:candidate"

log() { printf '[stack %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

down() {
  docker rm -f -v "$fe" "$be" "$pg" >/dev/null 2>&1 || true
  docker volume rm -f "$vol" "fv-${name}-uploads" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  docker image rm -f "$bimg" "$wimg" >/dev/null 2>&1 || true
  rm -rf "$dir"
  local left
  left="$(docker ps -a --filter "name=fv-${name}-" -q | wc -l) $(docker volume ls -q --filter "name=fv-${name}-" | wc -l)"
  log "down: containers/volumes left: $left"
}

wait_for() { # <seconds> <description> <cmd...>
  local secs="$1" what="$2"; shift 2
  local i
  for ((i = 0; i < secs; i += 2)); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  log "timed out waiting for $what"
  return 1
}

up() {
  local dbport="$4" apiport="$5" webport="$6" version="$7" commit="$8"
  local t0 t1 t2 t3
  t0=$(date +%s)
  rm -rf "$dir/src" && mkdir -p "$dir/src" && tar -xzf "$dir/src.tgz" -C "$dir/src"
  # The legacy builder: this host has no buildx. Both images build in parallel.
  log "building $bimg and $wimg"
  (docker build -q -f "$dir/src/Dockerfile" --build-arg "VERSION=v$version" --build-arg "COMMIT=$commit" \
      --build-arg "DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)" -t "$bimg" "$dir/src" >"$dir/build-backend.log" 2>&1; echo $? >"$dir/build-backend.rc") &
  (docker build -q -f "$dir/src/Dockerfile.web" --build-arg "NEXT_PUBLIC_APP_VERSION=v$version" \
      -t "$wimg" "$dir/src" >"$dir/build-web.log" 2>&1; echo $? >"$dir/build-web.rc") &
  wait
  for part in backend web; do
    if [[ "$(cat "$dir/build-$part.rc")" != 0 ]]; then
      tail -n 30 "$dir/build-$part.log" >&2
      log "build $part failed"
      return 1
    fi
  done
  t1=$(date +%s)

  local pw jwt
  pw="$(openssl rand -hex 16)"; jwt="$(openssl rand -hex 32)"
  docker network create "$net" >/dev/null
  docker volume create "$vol" >/dev/null
  docker run -d --name "$pg" --network "$net" --network-alias postgres -v "$vol:/var/lib/postgresql/data" \
    -e POSTGRES_DB=multica -e POSTGRES_USER=multica -e "POSTGRES_PASSWORD=$pw" \
    -p "127.0.0.1:$dbport:5432" pgvector/pgvector:pg17 >/dev/null
  wait_for 120 postgres docker exec "$pg" pg_isready -U multica -d multica
  printf '%s' "$pw" >"$dir/pgpw" && chmod 600 "$dir/pgpw"
  # A second, empty database for DB-backed Go tests (their fixtures must not
  # land in the restored copy the candidate server reads).
  docker exec "$pg" psql -U multica -d multica -qc 'CREATE DATABASE multica_gotest' >/dev/null
  # The dump came from a database whose role is also "multica"; --no-owner keeps
  # it portable if that ever changes. Restore errors on pre-existing extensions
  # are expected; a missing table is not (checked below).
  docker exec -i "$pg" pg_restore -U multica -d multica --no-owner --no-acl <"$dir/backup.dump" >"$dir/restore.log" 2>&1 || true
  local tables
  tables="$(docker exec "$pg" psql -U multica -d multica -Atc "select count(*) from information_schema.tables where table_schema='public'")"
  local before
  before="$(docker exec "$pg" psql -U multica -d multica -Atc 'select max(version) from schema_migrations')"
  log "restored: $tables tables, schema_migrations max=$before"
  [[ "$tables" -gt 50 ]] || { tail -n 20 "$dir/restore.log" >&2; log "restore produced too few tables"; return 1; }
  t2=$(date +%s)

  # APP_ENV=development enables MULTICA_DEV_VERIFICATION_CODE, the dev login path
  # the test user signs in with. The code is random per run and never printed.
  local devcode
  devcode="$(printf '%06d' $((0x$(openssl rand -hex 3) % 1000000)))"
  printf '%s' "$devcode" >"$dir/devcode" && chmod 600 "$dir/devcode"
  docker run -d --name "$be" --network "$net" --network-alias backend -v "fv-${name}-uploads:/app/data/uploads" \
    -e "DATABASE_URL=postgres://multica:$pw@postgres:5432/multica?sslmode=disable" -e PORT=8080 \
    -e "JWT_SECRET=$jwt" -e APP_ENV=development -e "MULTICA_DEV_VERIFICATION_CODE=$devcode" \
    -e "FRONTEND_ORIGIN=http://127.0.0.1:$webport" -e "MULTICA_APP_URL=http://127.0.0.1:$webport" \
    -e "MULTICA_PUBLIC_URL=http://127.0.0.1:$apiport" -e "MULTICA_DAEMON_SERVER_URL=http://127.0.0.1:$apiport" \
    -e ALLOW_SIGNUP=true -e DO_NOT_TRACK=1 -e MULTICA_VCS_INTEGRATION_ENABLED=false \
    -p "127.0.0.1:$apiport:8080" "$bimg" >/dev/null
  docker run -d --name "$fe" --network "$net" -e HOSTNAME=0.0.0.0 -e REMOTE_API_URL=http://backend:8080 \
    -p "127.0.0.1:$webport:3000" "$wimg" >/dev/null
  if ! wait_for 300 "backend readyz" curl -fsS "http://127.0.0.1:$apiport/readyz"; then
    docker logs --tail 40 "$be" >&2
    return 1
  fi
  wait_for 120 "web login page" curl -fsS -o /dev/null "http://127.0.0.1:$webport/login"
  t3=$(date +%s)
  local after
  after="$(docker exec "$pg" psql -U multica -d multica -Atc 'select max(version) from schema_migrations')"
  docker logs "$be" 2>&1 | grep -ciE 'migrat' >"$dir/migrate-lines" || true
  printf 'build_secs=%s\nrestore_secs=%s\nboot_secs=%s\nmigrations_before=%s\nmigrations_after=%s\ntables=%s\ngotest_db=ok\n' \
    $((t1 - t0)) $((t2 - t1)) $((t3 - t2)) "$before" "$after" "$tables" >"$dir/stack.env"
  cat "$dir/stack.env"
  docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' "$pg" "$be" "$fe" | sed 's/^/stats /'
}

case "$cmd" in
  up) up "$@" ;;
  down) down ;;
  *) echo "unknown command $cmd" >&2; exit 2 ;;
esac

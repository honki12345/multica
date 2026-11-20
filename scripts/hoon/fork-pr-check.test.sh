#!/usr/bin/env bash
# Tests for scripts/hoon/fork-pr-check.sh against throwaway git repositories.
#   bash scripts/hoon/fork-pr-check.test.sh
# No network: the "GitHub" is a local repo with refs/pull/<n>/head, `gh` is a
# stub (FPC_GH) that answers from files in $T/gh.
set -uo pipefail

SCRIPT="${FPC_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fork-pr-check.sh}"
fail=0
pass() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/fork-pr-check-test.XXXXXX")"
trap '/bin/rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
mkdir -p "$T/gh" "$T/tmp"

cat > "$T/gh/gh" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "${BASH_SOURCE[0]}")"
case "$1 $2" in
  "pr view") cat "$d/view-$3.json" ;;
  "pr comment")
    n="$3"
    [ -f "$d/post-fails" ] && { echo "boom" >&2; exit 1; }
    printf '%s\n' "$*" > "$d/posted-args"
    while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" "$d/posted-body"; shift; done
    echo "https://example.invalid/pull/$n#issuecomment-1" ;;
  "api repos/"*) [ -f "$d/api-fails" ] && { echo "boom" >&2; exit 1; }; cat "$d/comments-$(basename "$(dirname "$2")")".json ;;
  *) echo "stub gh: unexpected $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/gh/gh"
export FPC_GH="$T/gh/gh"

R="$T/remote"
git init -q -b main "$R"
cd "$R" || exit 1
mkdir -p scripts/hoon server/internal/a apps/web packages/core apps/mobile fork .github/workflows
printf '#!/bin/sh\necho "license-check: ok"\n' > scripts/hoon/license-check.sh
printf '#!/bin/sh\necho "features-check: base=v1.0.0 features=3 errors=0 warnings=0"\n' > scripts/hoon/features-check.sh
printf '#!/bin/sh\necho "old"\n' > scripts/hoon/other.sh
printf '#!/bin/sh\necho "other tests ok"\n' > scripts/hoon/other.test.sh
printf '#!/bin/sh\necho "feature tests ok"\n' > scripts/hoon/features-check.test.sh
printf 'package a\n' > server/internal/a/a.go
printf '{"name":"@multica/web","devDependencies":{"vitest":"catalog:"}}\n' > apps/web/package.json
printf '{"name":"@multica/core","devDependencies":{"vitest":"catalog:"}}\n' > packages/core/package.json
printf '{"name":"@multica/mobile","devDependencies":{"vitest":"catalog:"}}\n' > apps/mobile/package.json
printf 'x\n' > README.md
git add -A && git commit -qm "chore: upstream base" && git tag v1.0.0
BASE_SHA="$(git rev-parse HEAD)"
git update-ref refs/heads/other-base HEAD

# mkpr <n> — commit the files named on stdin ("path<TAB>content") onto a branch
# off main and publish it as refs/pull/<n>/head.
mkpr() {
  local n="$1" path content
  git -C "$R" checkout -q -b "pr$n" main
  while IFS=$'\t' read -r path content; do
    [ -n "$path" ] || continue
    mkdir -p "$R/$(dirname "$path")"
    printf '%b' "$content" > "$R/$path"
  done
  git -C "$R" add -A && git -C "$R" commit -qm "pr $n"
  git -C "$R" update-ref "refs/pull/$n/head" HEAD
  git -C "$R" checkout -q main
  setview "$n" "$(git -C "$R" rev-parse "refs/pull/$n/head")"
}
setview() { # <n> <head sha>
  printf '{"number":%s,"url":"https://example.invalid/pull/%s","headRefOid":"%s","headRefName":"pr%s","baseRefName":"main"}\n' "$1" "$1" "$2" "$1" > "$T/gh/view-$1.json"
}

W="$T/work"
git clone -q "$R" "$W"
cd "$W" || exit 1

fpc() { bash "$SCRIPT" "$@" --repo-url "$R" --upstream-url "$R"; }
plan() { fpc plan "$1" 2>&1; }
has() { printf '%s\n' "$2" | grep -qxF -- "$3" && pass "$1" || { bad "$1"; printf '%s\n' "$2"; }; }
hasnt() { printf '%s\n' "$2" | grep -qF -- "$3" && { bad "$1"; printf '%s\n' "$2"; } || pass "$1"; }
worktrees() { git -C "$W" worktree list --porcelain | grep -c '^worktree '; }
leftovers() { find "$T/tmp" -mindepth 1 -maxdepth 1 -name 'fork-pr-check.*' | wc -l | tr -d ' '; }

# --- plan: selection per rule
mkpr 1 <<'EOF'
README.md	y\n
EOF
out="$(plan 1)"
MB="$BASE_SHA"
has "plan: license check always" "$out" "bash scripts/hoon/license-check.sh"
has "plan: features check always" "$out" "bash scripts/hoon/features-check.sh"
has "plan: diff --check from the merge base" "$out" "git diff --check $MB..HEAD"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 3 ] && pass "plan: docs-only PR runs exactly the 3 always-checks" || { bad "plan: docs-only PR runs exactly the 3 always-checks"; echo "$out"; }

mkpr 2 <<'EOF'
scripts/hoon/other.sh	#!/bin/sh\necho "new"\n
scripts/hoon/brand-new.sh	#!/bin/sh\necho hi\n
EOF
out="$(plan 2)"
has "plan: changed X.sh runs the existing X.test.sh" "$out" "bash scripts/hoon/other.test.sh"
hasnt "plan: no test run for a script without X.test.sh" "$out" "brand-new.test.sh"
has "plan: shellcheck on every changed .sh" "$out" "shellcheck -S warning scripts/hoon/brand-new.sh scripts/hoon/other.sh"

mkpr 3 <<'EOF'
scripts/hoon/other.test.sh	#!/bin/sh\necho "other tests ok 2"\n
EOF
out="$(plan 3)"
has "plan: changed X.test.sh runs itself" "$out" "bash scripts/hoon/other.test.sh"
has "plan: shellcheck on a changed test script" "$out" "shellcheck -S warning scripts/hoon/other.test.sh"

mkpr 4 <<'EOF'
scripts/hoon/fork-verify/helper.py	print(1)\n
scripts/hoon/other/notes.md	n\n
EOF
out="$(plan 4)"
has "plan: file under scripts/hoon/X/ runs X.test.sh" "$out" "bash scripts/hoon/other.test.sh"
hasnt "plan: non-.sh file under scripts/hoon/X/ is not shellchecked" "$out" "shellcheck"

mkpr 5 <<'EOF'
fork/features.yml	version: 1\n
EOF
out="$(plan 5)"
has "plan: features.yml runs features-check.test.sh" "$out" "bash scripts/hoon/features-check.test.sh"

mkpr 6 <<'EOF'
.github/workflows/x.yml	name: x\n
EOF
out="$(plan 6)"
has "plan: .github change runs ci-scope test" "$out" "node --test scripts/ci-scope.test.mjs"
mkpr 7 <<'EOF'
scripts/check-x.mjs	export {};\n
EOF
out="$(plan 7)"
has "plan: scripts/*.mjs change runs ci-scope test" "$out" "node --test scripts/ci-scope.test.mjs"
hasnt "plan: no ci-scope test for unrelated PRs" "$(plan 1)" "ci-scope"

mkpr 8 <<'EOF'
server/internal/a/a.go	package a\nvar X = 1\n
server/internal/a/a_test.go	package a\n
server/cmd/z/main.go	package main\n
server/go.mod	module x\n
EOF
out="$(plan 8)"
has "plan: go test on the unique changed package dirs" "$out" "cd server && go test -p 2 ./cmd/z ./internal/a"
hasnt "plan: Go PR does not install or typecheck JS" "$out" "pnpm"

mkpr 9 <<'EOF'
apps/web/app/page.tsx	export {};\n
apps/web/app/other.ts	export {};\n
packages/core/src/q.ts	export {};\n
apps/mobile/src/m.ts	export {};\n
EOF
out="$(plan 9)"
has "plan: pnpm install frozen" "$out" "pnpm install --frozen-lockfile --prefer-offline"
has "plan: pnpm typecheck" "$out" "pnpm typecheck"
has "plan: vitest related per package, paths relative to the package" "$out" "pnpm --filter @multica/core exec vitest related src/q.ts --run --maxWorkers=2"
has "plan: vitest related lists every changed file of the package" "$out" "pnpm --filter @multica/web exec vitest related app/other.ts app/page.tsx --run --maxWorkers=2"
hasnt "plan: apps/mobile is excluded" "$out" "mobile"
hasnt "plan: never a full vitest run" "$out" "vitest run"

mkpr 10 <<'EOF'
apps/mobile/src/m.ts	export {};\n
EOF
hasnt "plan: mobile-only TS change triggers no pnpm" "$(plan 10)" "pnpm"

mkpr 11 <<'EOF'
README.md	changed on the PR branch\n
EOF
git -C "$R" checkout -q main && printf 'later\n' > "$R/later.txt" && git -C "$R" add -A && git -C "$R" commit -qm "main moves on"
out="$(plan 11)"
has "plan: diff --check uses the merge base, not the new main tip" "$out" "git diff --check $MB..HEAD"

out="$(fpc plan 8 --base "$BASE_SHA" 2>&1)"
has "plan: --base picks the diff base" "$out" "git diff --check $BASE_SHA..HEAD"
git -C "$R" checkout -q main && printf 'x\n' > "$R/m.txt" && git -C "$R" add -A && git -C "$R" commit -qm "m"
git -C "$R" update-ref refs/pull/12/head main && setview 12 "$(git -C "$R" rev-parse main)"
hasnt "plan: merged PR (head inside base) has nothing to select" "$(plan 12)" "pnpm"
has "plan: merged PR with --base <old base> selects from the real diff" "$(fpc plan 12 --base "$BASE_SHA" 2>&1)" "git diff --check $BASE_SHA..HEAD"

# --- run: pass, fail, head moved, cleanup
mkpr 20 <<'EOF'
README.md	pass\n
EOF
HEAD20="$(git -C "$R" rev-parse refs/pull/20/head)"
before="$(worktrees)"
out="$(TMPDIR="$T/tmp" fpc run 20 --out "$T/out20" 2>"$T/err20")"; rc=$?
[ "$rc" = 0 ] && pass "run: all checks pass -> exit 0" || { bad "run: all checks pass -> exit 0 (rc=$rc)"; cat "$T/err20"; }
has "run: title" "$out" "## 로컬 검사 (fork-pr-check)"
printf '%s\n' "$out" | grep -qE "head: \`$HEAD20\`" && pass "run: full 40-char head sha" || bad "run: full 40-char head sha"
printf '%s\n' "$out" | grep -qE "base: \`main\` @ \`$(git -C "$R" rev-parse refs/heads/main)\`" && pass "run: base ref and sha" || bad "run: base ref and sha"
printf '%s\n' "$out" | grep -qE "기기: $(hostname -s), $(uname -m)," && pass "run: machine line" || bad "run: machine line"
printf '%s\n' "$out" | grep -qE '시각\(UTC\): [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z' && pass "run: UTC timestamp" || bad "run: UTC timestamp"
has "run: table header" "$out" "| 명령 | 종료 코드 | 결과 | 시간 |"
printf '%s\n' "$out" | grep -qF '| `bash scripts/hoon/license-check.sh` | 0 | license-check: ok | ' && pass "run: row with exit code and summary" || { bad "run: row with exit code and summary"; echo "$out"; }
printf '%s\n' "$out" | grep -qF 'features-check: base=v1.0.0 features=3 errors=0 warnings=0' && pass "run: summary picks the result line" || bad "run: summary picks the result line"
has "run: pass verdict" "$out" "판정: 통과 (실패 0)"
has "run: full-vitest note" "$out" "전체 시험은 출시 CI에서 돈다(포크 규칙: 전체 vitest run 금지)"
has "run: machine marker" "$out" "<!-- fork-pr-check pr=20 head=$HEAD20 verdict=pass -->"
[ -f "$T/out20/01.log" ] && [ -f "$T/out20/comment.md" ] && pass "run: logs and comment saved under --out" || bad "run: logs and comment saved under --out"
[ "$(worktrees)" = "$before" ] && [ "$(leftovers)" = 0 ] && pass "run: worktree and temp dir removed" || bad "run: worktree and temp dir removed ($(worktrees) vs $before, leftovers $(leftovers))"
[ -z "$(git -C "$W" status --porcelain)" ] && pass "run: the invoking checkout stays clean" || bad "run: the invoking checkout stays clean"

mkpr 21 <<'EOF'
scripts/hoon/features-check.sh	#!/bin/sh\necho "features-check: base=v1.0.0 features=3 errors=2 warnings=0"\nexit 1\n
EOF
HEAD21="$(git -C "$R" rev-parse refs/pull/21/head)"
out="$(TMPDIR="$T/tmp" fpc run 21 --out "$T/out21" 2>/dev/null)"; rc=$?
[ "$rc" = 1 ] && pass "run: a failing check -> exit 1" || bad "run: a failing check -> exit 1 (rc=$rc)"
printf '%s\n' "$out" | grep -qF '| `bash scripts/hoon/features-check.sh` | 1 | features-check: base=v1.0.0 features=3 errors=2 warnings=0 | ' && pass "run: failing row carries exit code 1" || { bad "run: failing row carries exit code 1"; echo "$out"; }
printf '%s\n' "$out" | grep -qF '| `bash scripts/hoon/license-check.sh` | 0 |' && pass "run: later and earlier checks still run" || bad "run: later and earlier checks still run"
printf '%s\n' "$out" | grep -qE '^판정: 실패 1건 .*bash scripts/hoon/features-check.sh' && pass "run: fail verdict lists the failed command" || { bad "run: fail verdict lists the failed command"; echo "$out"; }
has "run: fail marker" "$out" "<!-- fork-pr-check pr=21 head=$HEAD21 verdict=fail -->"
[ "$(worktrees)" = "$before" ] && [ "$(leftovers)" = 0 ] && pass "run: worktree removed after a failing check" || bad "run: worktree removed after a failing check"

# SIGTERM while a check is running must still remove the worktree
mkpr 22 <<'EOF'
scripts/hoon/license-check.sh	#!/bin/sh\ntouch "$FPC_STARTED"\nsleep 2\n
EOF
FPC_STARTED="$T/started" TMPDIR="$T/tmp" bash "$SCRIPT" run 22 --repo-url "$R" --upstream-url "$R" --out "$T/out22" >/dev/null 2>&1 &
pid=$!
for _ in $(seq 100); do [ -e "$T/started" ] && break; sleep 0.1; done
kill -TERM "$pid"; wait "$pid"; rc=$?
[ "$rc" = 143 ] && [ "$(worktrees)" = "$before" ] && [ "$(leftovers)" = 0 ] && pass "run: worktree removed when the run is terminated" || bad "run: worktree removed when the run is terminated (rc=$rc)"

# DB env must not leak into the checks
mkpr 23 <<'EOF'
scripts/hoon/license-check.sh	#!/bin/sh\necho "db=${DATABASE_URL:-unset}"\n
EOF
out="$(DATABASE_URL=postgres://x TMPDIR="$T/tmp" fpc run 23 --out "$T/out23" 2>/dev/null)"
printf '%s\n' "$out" | grep -qF 'db=unset' && pass "run: DATABASE_URL is unset for the checks" || bad "run: DATABASE_URL is unset for the checks"

# head moved between gh and the fetch
mkpr 24 <<'EOF'
README.md	moved\n
EOF
setview 24 "$HEAD20"
out="$(TMPDIR="$T/tmp" fpc run 24 --out "$T/out24" 2>"$T/err24")"; rc=$?
[ "$rc" = 2 ] && grep -q 'head moved' "$T/err24" && [ -z "$out" ] && pass "run: head moved -> exit 2, no body" || { bad "run: head moved -> exit 2, no body (rc=$rc)"; cat "$T/err24"; }
[ "$(worktrees)" = "$before" ] && [ "$(leftovers)" = 0 ] && pass "run: head moved leaves no worktree" || bad "run: head moved leaves no worktree"

# setup errors
rm -f "$T/gh/view-99.json"
TMPDIR="$T/tmp" fpc run 99 >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "run: unknown PR -> exit 2" || bad "run: unknown PR -> exit 2 (rc=$rc)"
bash "$SCRIPT" run 20 --repo-url "$T/no-such-repo" --upstream-url "$R" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "run: unreachable remote -> exit 2" || bad "run: unreachable remote -> exit 2 (rc=$rc)"
bash "$SCRIPT" run >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "usage error -> exit 2" || bad "usage error -> exit 2 (rc=$rc)"

# --- run --post
out="$(TMPDIR="$T/tmp" fpc run 20 --post --repo acme/widgets --out "$T/out20p" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && pass "run --post: exit 0" || bad "run --post: exit 0 (rc=$rc)"
grep -qF 'pr comment 20 -R acme/widgets --body-file' "$T/gh/posted-args" && pass "run --post: gh pr comment with --repo and --body-file" || bad "run --post: gh pr comment with --repo and --body-file"
printf '%s\n' "$out" | tail -n 1 | grep -qF 'https://example.invalid/pull/20#issuecomment-1' && pass "run --post: prints the comment URL" || bad "run --post: prints the comment URL"
grep -qF "<!-- fork-pr-check pr=20 head=$HEAD20 verdict=pass -->" "$T/gh/posted-body" && pass "run --post: posted body has the marker" || bad "run --post: posted body has the marker"
touch "$T/gh/post-fails"
TMPDIR="$T/tmp" fpc run 20 --post --out "$T/out20q" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "run --post: post failure -> exit 2" || bad "run --post: post failure -> exit 2 (rc=$rc)"
rm -f "$T/gh/post-fails"
rm -f "$T/gh/posted-args"
TMPDIR="$T/tmp" fpc run 20 --out "$T/out20r" >/dev/null 2>&1
[ ! -e "$T/gh/posted-args" ] && pass "run without --post posts nothing" || bad "run without --post posts nothing"

# --- gate
HEAD="$(printf 'a%.0s' $(seq 40))"; OLD="$(printf 'b%.0s' $(seq 40))"
setview 30 "$HEAD"
comment() { # <id> <created_at> <assoc> <pr> <head> <verdict> [body prefix]
  printf '{"id":%s,"created_at":"%s","author_association":"%s","body":"%s## 로컬 검사\\n\\n<!-- fork-pr-check pr=%s head=%s verdict=%s -->"}' "$1" "$2" "$3" "${7:-}" "$4" "$5" "$6"
}
gate() { out="$(fpc gate 30 2>/dev/null)"; rc=$?; }
want() { # <name> <rc> <out>
  if [ "$rc" = "$2" ] && [ "$out" = "$3" ]; then pass "$1"; else bad "$1 (rc=$rc out='$out')"; fi
}

printf '[]' > "$T/gh/comments-30.json"; gate
want "gate: no comments -> blocked no-comment" 1 "gate=blocked reason=no-comment"
printf '[{"id":1,"created_at":"2026-01-01T00:00:00Z","author_association":"OWNER","body":"LGTM, no marker"}]' > "$T/gh/comments-30.json"; gate
want "gate: comment without marker -> no-comment" 1 "gate=blocked reason=no-comment"
printf '[%s]' "$(comment 1 2026-01-01T00:00:00Z OWNER 30 "$HEAD" pass)" > "$T/gh/comments-30.json"; gate
want "gate: marker head == current head, pass -> ok" 0 "gate=ok head=$HEAD"
printf '[%s]' "$(comment 1 2026-01-01T00:00:00Z OWNER 30 "$OLD" pass)" > "$T/gh/comments-30.json"; gate
want "gate: marker head != current head -> head-moved" 1 "gate=blocked reason=head-moved"
printf '[%s]' "$(comment 1 2026-01-01T00:00:00Z OWNER 30 "$HEAD" fail)" > "$T/gh/comments-30.json"; gate
want "gate: verdict=fail -> verdict-fail" 1 "gate=blocked reason=verdict-fail"
printf '[%s,%s]' "$(comment 1 2026-01-01T00:00:00Z OWNER 30 "$HEAD" pass)" "$(comment 2 2026-01-02T00:00:00Z OWNER 30 "$HEAD" fail)" > "$T/gh/comments-30.json"; gate
want "gate: newest marker wins (pass then fail)" 1 "gate=blocked reason=verdict-fail"
printf '[%s,%s]' "$(comment 2 2026-01-02T00:00:00Z OWNER 30 "$HEAD" pass)" "$(comment 1 2026-01-01T00:00:00Z OWNER 30 "$HEAD" fail)" > "$T/gh/comments-30.json"; gate
want "gate: newest marker wins regardless of list order (fail then pass)" 0 "gate=ok head=$HEAD"
printf '[%s,%s]' "$(comment 1 2026-01-01T00:00:00Z OWNER 30 "$HEAD" pass)" "$(comment 2 2026-01-02T00:00:00Z OWNER 30 "$OLD" pass)" > "$T/gh/comments-30.json"; gate
want "gate: an older pass for the current head does not outvote a newer head" 1 "gate=blocked reason=head-moved"
printf '[%s,%s]' "$(comment 1 2026-01-01T00:00:00Z OWNER 30 "$HEAD" pass)" "$(comment 2 2026-01-02T00:00:00Z NONE 30 "$HEAD" fail)" > "$T/gh/comments-30.json"; gate
want "gate: a stranger's newer comment is ignored" 0 "gate=ok head=$HEAD"
printf '[%s]' "$(comment 1 2026-01-01T00:00:00Z NONE 30 "$HEAD" pass)" > "$T/gh/comments-30.json"; gate
want "gate: a stranger's pass cannot open the gate" 1 "gate=blocked reason=no-comment"
printf '[%s,%s]' "$(comment 1 2026-01-01T00:00:00Z OWNER 30 "$HEAD" pass)" "$(comment 2 2026-01-02T00:00:00Z OWNER 31 "$HEAD" fail)" > "$T/gh/comments-30.json"; gate
want "gate: a marker for another PR is ignored" 0 "gate=ok head=$HEAD"
printf '[%s]' "$(comment 1 2026-01-01T00:00:00Z OWNER 30 "$HEAD" fail)" > "$T/gh/comments-30.json"
printf '[%s]' "$(comment 2 2026-01-02T00:00:00Z OWNER 30 "$HEAD" pass)" >> "$T/gh/comments-30.json"; gate
want "gate: --paginate output (concatenated arrays) is read" 0 "gate=ok head=$HEAD"
printf '[{"id":1,"created_at":"2026-01-01T00:00:00Z","author_association":"OWNER","body":"%s\\n\\n> <!-- fork-pr-check pr=30 head=%s verdict=fail -->\\n\\nquoted: <!-- fork-pr-check pr=30 head=%s verdict=fail -->"}]' \
  "<!-- fork-pr-check pr=30 head=$HEAD verdict=pass -->" "$OLD" "$OLD" > "$T/gh/comments-30.json"; gate
want "gate: markers quoted in prose after the real one do not count" 0 "gate=ok head=$HEAD"
touch "$T/gh/api-fails"; gate
[ "$rc" = 2 ] && pass "gate: gh api failure -> exit 2 (not ok)" || bad "gate: gh api failure -> exit 2 (rc=$rc out='$out')"
rm -f "$T/gh/api-fails"

# gate against a real run's comment
printf '[{"id":1,"created_at":"2026-01-01T00:00:00Z","author_association":"OWNER","body":%s}]' "$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' < "$T/out20/comment.md")" > "$T/gh/comments-20.json"
setview 20 "$HEAD20"
out="$(fpc gate 20 2>/dev/null)"; rc=$?
want "gate: accepts the comment that run produced" 0 "gate=ok head=$HEAD20"

exit "$fail"

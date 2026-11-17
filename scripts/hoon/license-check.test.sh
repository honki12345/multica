#!/usr/bin/env bash
# Tests for scripts/hoon/license-check.sh against throwaway git repositories.
#   bash scripts/hoon/license-check.test.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/license-check.sh"
fail=0
pass() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/license-check-test.XXXXXX")"
trap '/bin/rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# Upstream v1.0.0, then the fork on top of it.
setup() {
  local d="$T/$1"
  git init -q -b main "$d"
  cd "$d" || exit 1
  mkdir -p server packages/views/brand
  printf 'Multica License\nApache 2.0\n' > LICENSE
  printf 'Multica\nCopyright Index Labs\n' > NOTICE
  printf 'package a\n' > server/a.go
  printf 'package b\n' > server/b.go
  printf 'line\n' > server/gen.go
  printf '<svg/>\n' > packages/views/brand/logo.svg
  printf 'export const t = "Ask Multica";\n// Multica comment\n' > packages/views/bar.tsx
  git add -A && git commit -qm upstream && git update-ref refs/upstream-tags/v1.0.0 HEAD
  printf '\nThis distribution is a modified fork.\n' >> NOTICE
  printf '// Modified by honki12345, 2026: x\npackage a\nfunc A() {}\n' > server/a.go
  printf 'line2\n' > server/gen.go
  cat > FORK.md <<'EOF'
# fork

## Modified files without an inline notice

| File | Reason |
|---|---|
| `server/gen.go` | generated |

## Other
EOF
  git add -A && git commit -qm fork
}
run() { bash "$SCRIPT" "$@" > "$T/out" 2>&1; echo $?; }
expect() { # $1=name $2=expected exit $3=actual exit $4=grep pattern (optional)
  if [ "$2" = "$3" ] && { [ -z "${4:-}" ] || grep -qE -- "$4" "$T/out"; }; then pass "$1"; else bad "$1 (exit $3)"; cat "$T/out"; fi
}

setup clean
expect "clean fork passes" 0 "$(run)" 'errors=0 warnings=0'

setup license
printf 'x\n' >> LICENSE && git commit -qam l
expect "changed LICENSE fails" 1 "$(run)" 'LICENSE differs'

setup notice
printf 'Multica\n\nThis distribution is a modified fork.\n' > NOTICE && git commit -qam n
expect "dropped NOTICE line fails" 1 "$(run)" 'NOTICE dropped or changed 1'

setup unmarked
printf 'package b\nfunc B() {}\n' > server/b.go && git commit -qam b
expect "unmarked modified file fails" 1 "$(run)" 'no .Modified by honki12345. notice.*server/b.go'

setup late-mark
{ for _ in $(seq 31); do echo '//'; done; echo '// Modified by honki12345, 2026: late'; } > server/b.go && git commit -qam b
expect "notice after line 30 fails" 1 "$(run)" 'server/b.go'

setup deleted
git rm -q server/b.go && git commit -qm d
expect "deleted upstream file fails" 1 "$(run)" 'deleted but not listed.*server/b.go'

setup exempt
expect "FORK.md listed file is exempt" 0 "$(run)" 'errors=0'
sed -i.bak '/server\/gen.go/d' FORK.md && /bin/rm FORK.md.bak && git commit -qam e
expect "removing FORK.md entry fails" 1 "$(run)" 'server/gen.go'

setup new-file
printf 'package c\n' > server/c.go && git add -A && git commit -qm c
expect "new fork file needs no notice" 0 "$(run)" 'errors=0'

setup logo
printf '<svg id="x"/>\n' > packages/views/brand/logo.svg && git commit -qam logo
expect "unlisted logo change fails and warns" 1 "$(run)" 'UI logo/brand asset changed.*logo.svg'
awk '{ print } /^\| `server\/gen.go`/ { print "| `packages/views/brand/logo.svg` | asset |" }' FORK.md > FORK.tmp && mv FORK.tmp FORK.md && git commit -qam listed
expect "listed logo change only warns" 0 "$(run)" 'errors=0 warnings=1'

setup brand-text
printf '// Modified by honki12345, 2026: rename\nexport const t = "Ask Hoon";\n' > packages/views/bar.tsx && git commit -qam t
expect "lost Multica UI text warns but passes" 0 "$(run)" 'lost 1 line.*bar.tsx'

setup comment-only
printf '// Modified by honki12345, 2026: drop comment\nexport const t = "Ask Multica";\n' > packages/views/bar.tsx && git commit -qam c
expect "dropping a Multica code comment does not warn" 0 "$(run)" 'warnings=0'

setup newer-tag
git checkout -q -b up refs/upstream-tags/v1.0.0
printf 'Multica License v2\n' > LICENSE && git commit -qam up2 && git update-ref refs/upstream-tags/v1.1.0 HEAD
git checkout -q main
expect "base is newest merged tag; newer LICENSE warns" 0 "$(run)" 'base=v1.0.0 latest=v1.1.0.*warnings=1'

setup no-tags
expect "missing tags fail" 1 "$(run --tag-prefix refs/nothing)" 'no upstream release tags'

[ "$fail" = 0 ] && echo "all license-check tests passed"
exit "$fail"

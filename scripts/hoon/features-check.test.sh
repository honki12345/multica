#!/usr/bin/env bash
# Tests for scripts/hoon/features-check.sh against throwaway git repositories.
#   bash scripts/hoon/features-check.test.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/features-check.sh"
fail=0
pass() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/features-check-test.XXXXXX")"
trap '/bin/rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# Upstream v1.0.0 with a Go package and a views component, then one fork
# feature that changes both and adds a test of each kind.
setup() {
  local d="$T/$1"
  git init -q -b main "$d"
  cd "$d" || exit 1
  mkdir -p server/pkg views fork scripts/hoon
  printf 'package pkg\nfunc A() {}\n' > server/pkg/a.go
  printf 'package pkg\n' > server/pkg/near.go
  printf 'export const bar = 1;\n' > views/bar.tsx
  printf 'x\n' > NOTICE
  git add -A && git commit -qm upstream && git update-ref refs/upstream-tags/v1.0.0 HEAD
  printf 'x\nfork\n' > NOTICE
  printf 'package pkg\nfunc A() { B() }\n' > server/pkg/a.go
  printf 'package pkg\nfunc B() {}\n' > server/pkg/b.go
  printf 'package pkg\nimport "testing"\nfunc TestB(t *testing.T) {}\n' > server/pkg/b_test.go
  printf 'export const bar = 2;\n' > views/bar.tsx
  printf 'it("shows every chip", () => {});\n' > views/bar.test.tsx
  printf '#!/bin/sh\n' > scripts/hoon/tool.sh
  git add -A && git commit -qm feature
  FEATURE_SHA="$(git rev-parse --short HEAD)"
  write_registry
  git add -A && git commit -qm registry
}
write_registry() {
  cat > fork/features.yml <<EOF
version: 1
infrastructure:
  - path: NOTICE
  - path: fork/**
  - path: scripts/hoon/**
features:
  - id: b-feature
    summary: B everywhere.
    status: active
    kind: server
    cards: [CALA-1]
    origin:
      type: ours
      commits: [$FEATURE_SHA]
    files:
      - server/pkg/a.go
      - server/pkg/b.go
      - server/pkg/b_test.go
      - views/bar.tsx
      - views/bar.test.tsx
    watch:
      - path: server/pkg/near.go
        why: neighbour of a.go
    upstream_equivalent:
      keywords: [b feature]
    tests:
      - go: server/pkg
        name: TestB
      - vitest: views/bar.test.tsx
        name: shows every chip
    scenarios:
      - name: B runs
        steps: [Run B.]
        expect: [B ran.]
    drop_when: upstream ships B.
EOF
}
edit() { # $1 = sed expression applied to the registry, then committed
  sed -i.bak "$1" fork/features.yml && /bin/rm fork/features.yml.bak && git commit -qam edit
}
run() { bash "$SCRIPT" "$@" > "$T/out" 2>&1; echo $?; }
expect() { # $1=name $2=expected exit $3=actual exit $4=grep pattern (optional)
  if [ "$2" = "$3" ] && { [ -z "${4:-}" ] || grep -qE -- "$4" "$T/out"; }; then pass "$1"; else bad "$1 (exit $3)"; cat "$T/out"; fi
}

setup clean
expect "clean registry passes" 0 "$(run)" 'base=v1.0.0 features=1 errors=0 warnings=0'

setup unclaimed
printf 'package pkg\nfunc A() { B(); B() }\n' > server/pkg/near.go && git commit -qam near
expect "modified upstream file outside every feature fails" 1 "$(run)" 'modified file is claimed by no feature.*server/pkg/near.go'

setup unclaimed-new
printf 'package pkg\n' > server/pkg/c.go && git add -A && git commit -qm c
expect "new fork file outside every feature fails" 1 "$(run)" 'added file is claimed by no feature.*server/pkg/c.go'

setup unclaimed-deleted
git rm -q server/pkg/near.go && edit '/near.go/,/neighbour/d'
expect "deleted upstream file outside every feature fails" 1 "$(run)" 'deleted file is claimed by no feature.*server/pkg/near.go'

setup infra
printf 'x\n' > scripts/hoon/other.sh && git add -A && git commit -qm infra
expect "infrastructure glob claims fork tooling" 0 "$(run)" 'errors=0'

setup missing-file
edit 's#      - views/bar.test.tsx#      - views/bar.test.tsx\n      - views/gone.tsx#'
expect "files entry missing at head fails" 1 "$(run)" 'file not found at HEAD: views/gone.tsx'

setup missing-watch
edit 's#server/pkg/near.go#server/pkg/nope/**#'
expect "watch glob matching nothing fails" 1 "$(run)" 'watch matches no file: server/pkg/nope/\*\*'

setup missing-go-test
edit 's#name: TestB$#name: TestGone#'
expect "unknown Go test fails" 1 "$(run)" 'Go test TestGone not found in server/pkg'

setup missing-vitest-case
edit 's#name: shows every chip#name: shows no chip#'
expect "unknown vitest case fails" 1 "$(run)" "vitest case 'shows no chip' not found"

setup missing-vitest-file
edit 's#vitest: views/bar.test.tsx#vitest: views/gone.test.tsx#'
expect "unknown vitest file fails" 1 "$(run)" 'vitest file not found: views/gone.test.tsx'

setup bad-kind
edit 's#kind: server#kind: backend#'
expect "unknown kind fails" 1 "$(run)" 'feature b-feature: kind must be one of'

setup bad-commit
edit "s#commits: \[.*\]#commits: [deadbeef]#"
expect "unknown origin commit fails" 1 "$(run)" 'origin commit deadbeef not found'

setup no-tests
edit '/^    tests:/,/^    scenarios:/{/^    scenarios:/!d;}'
expect "active feature without tests or tests_gap fails" 1 "$(run)" 'needs tests, or tests_gap'
edit 's#^    scenarios:#    tests_gap: covered by the scenario only.\n    scenarios:#'
expect "tests_gap stands in for tests" 0 "$(run)" 'errors=0'

setup colon-in-step
edit 's#expect: \[B ran.\]#expect:\n          - B prints "x (branch: y)".#'
expect "a step YAML parses as a mapping fails" 1 "$(run)" 'each scenario needs name, steps and expect'

setup duplicate
sed -n '/^  - id: b-feature/,$p' fork/features.yml >> fork/features.yml && git commit -qam dup
expect "duplicate id fails" 1 "$(run)" 'feature b-feature: duplicate id'

setup stale
git checkout -q refs/upstream-tags/v1.0.0 -- views/bar.tsx && git commit -qm revert-bar
expect "file identical to upstream only warns" 0 "$(run)" 'views/bar.tsx is identical to upstream v1.0.0'
expect "...and the warning does not fail the run" 0 "$(run)" 'errors=0 warnings=1'

setup planned
cat >> fork/features.yml <<'EOF'
  - id: c-planned
    summary: C later.
    status: planned
    kind: web-ui
    origin: {type: ours}
    files: [views/bar.tsx]
    upstream_equivalent: {keywords: [c]}
    drop_when: upstream ships C.
EOF
git commit -qam planned
expect "planned feature touching a changed file only warns" 0 "$(run)" 'planned feature c-planned: views/bar.tsx already differs'

setup bad-yaml
printf 'version: 1\nfeatures: [\n' > fork/features.yml && git commit -qam broken
expect "invalid YAML fails" 1 "$(run)" 'registry is not valid YAML'

setup reads-head
printf 'garbage: [\n' > fork/features.yml
expect "uncommitted registry edits are not read" 0 "$(run)" 'errors=0'

setup no-tags
expect "missing tags fail" 1 "$(run --tag-prefix refs/nothing)" 'no upstream release tags'

[ "$fail" = 0 ] && echo "all features-check tests passed"
exit "$fail"

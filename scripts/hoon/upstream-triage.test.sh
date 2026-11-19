#!/usr/bin/env bash
# Tests for scripts/hoon/upstream-triage.sh against throwaway git repositories.
#   bash scripts/hoon/upstream-triage.test.sh
# No network: release notes, PR metadata and the CLI --help tree come from the
# TRIAGE_*_OVERRIDE files.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/upstream-triage.sh"
fail=0
pass() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/upstream-triage-test.XXXXXX")"
trap '/bin/rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# Upstream v1.0.0; the fork changes core.go and bar.tsx and registers one
# active and one planned feature. Upstream then ships v1.1.0 with one commit
# per triage class.
setup() {
  local d="$T/$1"
  git init -q -b main "$d"
  cd "$d" || exit 1
  mkdir -p server/pkg server/migrations server/cmd/multica views fork
  printf 'package pkg\nfunc Core() {}\n' > server/pkg/core.go
  printf 'package pkg\n' > server/pkg/near.go
  printf 'export const bar = 1;\n' > views/bar.tsx
  printf 'export const list = 1;\n' > views/list.tsx
  printf 'A=1\n' > .env.example
  printf 'package main\nvar rootCmd = &cobra.Command{Use: "multica"}\n' > server/cmd/multica/main.go
  printf 'package main\n' > server/cmd/multica/cmd_inbox.go
  printf 'package pkg\nfunc OldHelper() {}\n' > server/pkg/old.go
  git add -A && git commit -qm "chore: upstream base" && git tag v1.0.0
  git checkout -q -b fork
  printf 'package pkg\nfunc Core() { Ours() }\n' > server/pkg/core.go
  printf 'export const bar = 2;\n' > views/bar.tsx
  cat > fork/features.yml <<'EOF'
version: 1
features:
  - id: core-ours
    summary: Our core change.
    status: active
    kind: server
    cards: [CALA-1]
    origin: {type: ours, commits: []}
    files: [server/pkg/core.go]
    watch:
      - {path: server/pkg/near.go, why: neighbour}
    upstream_equivalent:
      prs: [42]
      symbols: [OursEverywhere, OldHelper]
      keywords: [core ours]
    drop_when: upstream ships core ours.
  - id: list-filters
    summary: Filters on the list.
    status: planned
    kind: web-ui
    cards: [CALA-2]
    origin: {type: ours}
    files: [views/list.tsx]
    upstream_equivalent:
      keywords: [list filter]
    drop_when: upstream ships list filters.
EOF
  git add -A && git commit -qm "feat: fork"
  git checkout -q main
  commit() { git add -A && git commit -qm "$1"; }
  printf 'package pkg\nfunc Core() { Theirs() }\n' > server/pkg/core.go; commit "fix(core): reshape core (#41)"
  printf 'package pkg\nfunc Near() {}\n' > server/pkg/near.go; commit "fix(pkg): touch the neighbour (#43)"
  printf 'package pkg\nfunc OursEverywhere() {}\n' > server/pkg/eq.go; commit "fix(pkg): something unrelated by title (#44)"
  printf 'package pkg\nfunc OldHelper() { _ = 1 }\n' > server/pkg/old.go; commit "fix(pkg): old helper grows (#45)"
  printf 'x\n' > server/pkg/pr42.go; commit "fix(pkg): the one the registry tracks (#42)"
  printf 'export const list = 2;\n' > views/list.tsx; commit "feat(views): add list filter menu (#46)"
  printf 'create table t();\n' > server/migrations/101_t.up.sql
  printf 'drop table t;\n' > server/migrations/101_t.down.sql
  printf 'create index i on t();\n' > server/migrations/102_t_idx.up.sql; commit "feat(db): table t (#47)"
  printf 'A=1\nNEW_SECRET_KEY=\n# OPTIONAL_KNOB=3\nA=1\n' > .env.example; commit "feat(weixin): new channel (#48)"
  printf 'package main\nvar inboxCmd = &cobra.Command{Use: "inbox"}\nvar inboxListCmd = &cobra.Command{Use: "list"}\n' > server/cmd/multica/cmd_inbox.go; commit "feat(cli): add inbox list (#49)"
  printf 'package pkg\nimport "os"\nvar _ = os.Getenv("SERVER_ONLY_KEY")\n' > server/pkg/env.go; commit "fix(pkg): read a server key (#50)"
  printf '# docs\n' > README.md; commit "docs: readme (#51)"
  git tag v1.1.0
  printf 'export const bar = 3;\n' > views/bar.tsx; commit "fix(views): bar after the tag (#52)"
  git tag v1.2.0
  cat > "$T/notes" <<'EOF'
## Changelog
* 0000000 placeholder that matches nothing
EOF
  printf '{"41":{"title":"fix(core): reshape core","labels":[]},"46":{"title":"feat(views): add list filter menu","labels":["ui"]}}\n' > "$T/prs.json"
  printf '{"from":["issue","issue list"],"to":["issue","issue list","inbox","inbox list"]}\n' > "$T/cli.json"
}

run() {
  TRIAGE_RELEASE_NOTES_OVERRIDE="$T/notes" TRIAGE_PRS_OVERRIDE="$T/prs.json" TRIAGE_CLI_OVERRIDE="$T/cli.json" \
    bash "$SCRIPT" "$@" > "$T/out" 2>&1
  echo $?
}
key() { sed -n "s/^$1=//p" "$T/out"; }
expect() { # $1=name $2=pattern (grep -E on the report)
  if grep -qE -- "$2" "$T/out"; then pass "$1"; else bad "$1"; cat "$T/out"; fi
}
expect_key() { # $1=name $2=key $3=value
  local got; got="$(key "$2")"
  if [ "$got" = "$3" ]; then pass "$1"; else bad "$1 ($2: want '$3', got '$got')"; fi
}
row() { grep -E "^\| \`$(git rev-parse --short=9 ":/$1")\`" "$T/out"; }

setup base
rc="$(run v1.0.0 v1.1.0 --fork-ref fork --registry-ref fork --json "$T/out.json")"
if [ "$rc" = 0 ]; then pass "exits 0"; else bad "exits 0 (got $rc)"; fi
expect_key "status ok" triage_status ok
expect_key "counts every non-merge commit in the range" triage_commits 11
expect_key "fork merge conflicts on the shared file" triage_merge conflict
expect_key "conflict files" triage_conflict_files server/pkg/core.go
expect_key "A: our file changed upstream" triage_a 1
expect_key "A names the feature" triage_a_features core-ours
expect "A marks the conflicting file" "reshape core .*core-ours.*core.go ⚔️충돌"
expect_key "B: watch path and a planned feature's file" triage_b 2
expect_key "B names both features" triage_b_features core-ours,list-filters
expect_key "C: tracked PR, new symbol, keyword" triage_c 3
expect "C by tracked PR number" "the one the registry tracks.*PR #42이 레지스트리에 등록됨"
expect "C by a symbol upstream did not have before" "something unrelated by title.*새 심볼 \`OursEverywhere\`"
expect "C by keyword in the PR title" "add list filter menu.*\`list-filters\` \(CALA-2\).*키워드 \`list filter\`"
if row "old helper grows" | grep -q 'core-ours'; then bad "a symbol already at <from> is not C"; else pass "a symbol already at <from> is not C"; fi
expect_key "D: migration, .env.example and os.Getenv commits" triage_d 3
expect_key "new up migrations only" triage_migrations 2
expect_key "migration range" triage_migration_range 101-102
expect_key "new env keys: .env.example (commented too) and os.Getenv" triage_new_env NEW_SECRET_KEY,OPTIONAL_KNOB,SERVER_ONLY_KEY
expect_key "E: only feat commits naming our areas" triage_e 1
expect "E carries the area" "add inbox list.*\| cli, inbox \|"
expect_key "CLI tree diff" triage_new_cli inbox,inbox.list
expect "CLI commit from the cobra Use: source" "cmd_inbox.go\`: \`inbox\`, \`list\`"
expect_key "F: the rest" triage_f 2
expect "F lists the docs commit" "^- \`[0-9a-f]{9}\` .*docs: readme"
expect "F holds a commit no rule matches" "^- \`[0-9a-f]{9}\` .*old helper grows"
expect "ends with the confirm-from-PR-body instruction" "C 후보:.*PR 본문"
expect "release notes coverage gap reported" "릴리스 노트에 없는 커밋 11개"
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert {s["feature"] for s in d["screen_inputs"]} == {"core-ours","list-filters"}; assert d["migrations"][0]["number"] == 101' "$T/out.json"; then
  pass "JSON carries the B screen inputs and migrations"
else
  bad "JSON carries the B screen inputs and migrations"
fi

cp "$T/out" "$T/first"
run v1.0.0 v1.1.0 --fork-ref fork --registry-ref fork --json "$T/out2.json" >/dev/null
if cmp -s "$T/first" "$T/out" && cmp -s "$T/out.json" "$T/out2.json"; then pass "output is deterministic"; else bad "output is deterministic"; fi

setup env-already
git checkout -q -b pre v1.0.0 && printf 'A=1\nNEW_SECRET_KEY=\n' > .env.example && git commit -qam "chore: env" && git tag v1.0.5 && git checkout -q main
run v1.0.5 v1.1.0 --fork-ref fork --registry-ref fork >/dev/null
if [ "$(key triage_new_env)" = "OPTIONAL_KNOB,SERVER_ONLY_KEY" ]; then pass "env key present at <from> is not new"; else bad "env key present at <from> is not new ($(key triage_new_env))"; fi

setup merged
git checkout -q fork && git merge -q --no-edit -X ours v1.1.0 >/dev/null 2>&1; git checkout -q main
run v1.0.0 v1.1.0 --fork-ref fork --registry-ref fork >/dev/null
expect_key "already-merged target" triage_merge already-merged

setup clean
run v1.1.0 v1.2.0 --fork-ref v1.1.0 --registry-ref fork >/dev/null
expect_key "clean merge" triage_merge clean
expect_key "an active feature's file changed only by upstream is A, not B" triage_a 0
expect_key "...and B through its own files is not counted for active" triage_b 0

setup missing-ref
run v1.0.0 v9.9.9 >/dev/null
expect_key "unknown ref reports an error key" triage_status error
expect "...with the reason" "ref v9.9.9 not found"
rc="$(run v1.0.0 v9.9.9)"
if [ "$rc" = 0 ]; then pass "...and still exits 0"; else bad "...and still exits 0 (got $rc)"; fi

setup no-registry
run v1.0.0 v1.1.0 --registry-ref main >/dev/null
expect "missing registry reports an error" "registry fork/features.yml not found at main"

setup no-notes
: > "$T/notes"
run v1.0.0 v1.1.0 --fork-ref fork --registry-ref fork >/dev/null
expect_key "empty release notes override means none" triage_release_notes none

setup cli-off
TRIAGE_RELEASE_NOTES_OVERRIDE="$T/notes" TRIAGE_PRS_OVERRIDE="$T/prs.json" TRIAGE_CLI_OVERRIDE=off \
  bash "$SCRIPT" v1.0.0 v1.1.0 --fork-ref fork --registry-ref fork > "$T/out" 2>&1
expect_key "CLI build can be skipped" triage_cli_help skipped
expect_key "...falling back to the source Use: list" triage_new_cli inbox,list

if rc="$(bash "$SCRIPT" 2>/dev/null)"; then bad "no arguments is a usage error"; else pass "no arguments is a usage error"; fi

[ "$fail" = 0 ] && echo "all upstream-triage tests passed"
exit "$fail"

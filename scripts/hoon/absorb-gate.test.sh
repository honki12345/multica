#!/usr/bin/env bash
# Tests for scripts/hoon/absorb-gate.sh with small fixtures. No network, no git
# repository needed (the registry is read from a file).
#   bash scripts/hoon/absorb-gate.test.sh
# ABSORB_GATE_SCRIPT=<path> runs the same checks against another copy of the
# script (used to confirm each check fails when the behaviour is broken).
set -uo pipefail

SCRIPT="${ABSORB_GATE_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/absorb-gate.sh}"
fail=0
pass() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/absorb-gate-test.XXXXXX")"
trap '/bin/rm -rf "$T"' EXIT
T="$(cd "$T" && pwd)" # TMPDIR may end in a slash; the script prints normalised absolute paths

if python3 -c 'import yaml' 2>/dev/null; then
  PY=(python3)
else
  PY=(uv run -q --no-project --with pyyaml python3)
fi

# ---------- fixtures ----------

# A throwaway repository for --candidate / --merge-commit: the candidate, a
# merge commit with the same tree, and a commit with another tree. The script
# resolves revs in its working directory.
G="$T/repo"
git init -q -b main "$G"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
printf 'a\n' > "$G/a.txt"
git -C "$G" add -A && git -C "$G" commit -qm candidate
CAND="$(git -C "$G" rev-parse HEAD)"
git -C "$G" commit -q --allow-empty -m "same tree, other commit"
SAMETREE="$(git -C "$G" rev-parse HEAD)"
printf 'b\n' > "$G/a.txt"
git -C "$G" commit -qam "other tree"
OTHERTREE="$(git -C "$G" rev-parse HEAD)"

cat > "$T/triage.json" <<'EOF'
{
  "from": "v1.0.0",
  "to": "v1.1.0",
  "fork_ref": "v1.0.0-hoon.1",
  "merge": "conflict",
  "conflict_files": ["server/pkg/core.go"],
  "migrations": [{"name": "a", "number": 7}, {"name": "b", "number": 8}],
  "new_env": ["NEW_KEY"],
  "new_cli": ["thing list"],
  "removed_cli": [],
  "screen_inputs": [],
  "cli_help": "ok",
  "commits": [
    {"sha": "aaaaaaaaaaaa1111", "pr": 101, "subject": "feat(cli): thing list (#101)", "pr_labels": [], "cli": [],
     "labels": {"C": [{"feature": "core-ours", "status": "active", "cards": ["CALA-1"], "drop_when": "upstream ships thing list", "evidence": ["PR #101이 레지스트리에 등록됨"]}], "E": ["cli"]}},
    {"sha": "bbbbbbbbbbbb2222", "pr": 102, "subject": "feat(chat): wakeups (#102)", "pr_labels": [], "cli": [],
     "labels": {"C": [{"feature": "wake-plan", "status": "planned", "cards": ["CALA-5"], "drop_when": "upstream wakes chats", "evidence": ["키워드 `chat wakeup`"]}]}},
    {"sha": "cccccccccccc3333", "pr": 103, "subject": "feat(inbox): archive all (#103)", "pr_labels": [], "cli": [],
     "labels": {"E": ["inbox"]}},
    {"sha": "dddddddddddd4444", "pr": 104, "subject": "fix: typo (#104)", "pr_labels": [], "cli": [],
     "labels": {"F": true}}
  ]
}
EOF
printf '# 상류 변경 판별\n' > "$T/triage.md"

cat > "$T/features.yml" <<'EOF'
version: 1
features:
  - id: core-ours
    summary: Our core change.
    status: active
    kind: server
    cards: [CALA-1, CALA-2]
  - id: wake-plan
    summary: Planned wake feature.
    status: planned
    kind: cli
    cards: [CALA-5]
  - id: gone-feature
    summary: Already dropped.
    status: dropped
    kind: cli
    cards: [CALA-9]
  - id: quiet-ui
    summary: A UI tweak no upstream commit touches.
    status: active
    kind: web-ui
    cards: []
EOF

cat > "$T/cards.json" <<'EOF'
{"has_more": false, "issues": [
  {"identifier": "CALA-1", "status": "done", "title": "registered and done"},
  {"identifier": "CALA-2", "status": "in_progress", "title": "registered and open"},
  {"identifier": "CALA-5", "status": "in_review", "title": "registered planned"},
  {"identifier": "CALA-7", "status": "in_progress", "title": "open card outside the registry"},
  {"identifier": "CALA-8", "status": "done", "title": "closed card outside the registry"},
  {"identifier": "CALA-10", "status": "backlog", "title": "another open card"},
  {"identifier": "CALA-11", "status": "cancelled", "title": "cancelled card"},
  {"identifier": "CALA-99", "status": "in_progress", "title": "the absorb card itself"}
]}
EOF

# fork-verify output: one passing feature, one n/a feature, 3 screen shots
# (two with a region image, one compare-only).
mkv() {
  local d="$1" verdict="$2" code="$3"
  mkdir -p "$d/screens"
  cat > "$d/result.json" <<EOF
{"ref": "cand", "sha": "$CAND", "exit": $code, "checks": [
  {"feature": "core-ours", "layer": "test", "name": "go pkg TestA", "verdict": "pass", "detail": "통과 (1s)", "evidence": []},
  {"feature": "core-ours", "layer": "scenario", "name": "does the thing", "verdict": "$verdict", "detail": "detail-of-scenario", "evidence": []},
  {"feature": "quiet-ui", "layer": "screen", "name": "bar @1440", "verdict": "pass", "detail": "ok", "evidence": []},
  {"feature": "quiet-ui", "layer": "screen", "name": "bar @900", "verdict": "pass", "detail": "ok", "evidence": []},
  {"feature": "wake-plan", "layer": "scenario", "name": "planned", "verdict": "n/a", "detail": "status: planned", "evidence": []}
]}
EOF
  for n in shot-1440 shot-900 shot-700; do
    : > "$d/screens/$n.prod.png"; : > "$d/screens/$n.cand.png"; : > "$d/screens/$n.compare.png"
  done
  : > "$d/screens/shot-1440.region.png"; : > "$d/screens/shot-900.region.png"
}
mkv "$T/fv-ok" pass 0
mkv "$T/fv-fail" fail 1
mkv "$T/fv-unverified" unverified 0

# A decisions file filled from the template; later cases edit single lines.
GOOD="$T/decisions.yml"
fill() {
  "${PY[@]}" - "$1" "$2" <<'PY'
import sys
import yaml
d = yaml.safe_load(open(sys.argv[1]))
for c in d["candidates"]:
    c["verdict"] = {"C": "줄임", "E": "흡수"}[c["kind"]]
    c["reason"] = "PR 본문 확인"
for r in d["upstream_priority"]:
    r["verdict"] = "상류 위에 남은 것만"
    r["evidence"] = "PR #101 본문, 시험 통과"
    r["action"] = "없음"
yaml.safe_dump(d, open(sys.argv[2], "w"), allow_unicode=True, sort_keys=False)
PY
}

run() { (cd "$G" && bash "$SCRIPT" "$@"); }
tmpl() { run template --triage "$T/triage.json" --registry "$T/features.yml" --cards "$T/cards.json" --exclude-card CALA-99 "$@"; }
cmt() { run comment --triage "$T/triage.json" --decisions "${DEC:-$GOOD}" --verify "${FV:-$T/fv-ok}" --triage-md "$T/triage.md" --registry "$T/features.yml" --cards "${CARDS:-$T/cards.json}" --exclude-card CALA-99 --candidate "${CANDIDATE:-$CAND}" "$@"; }

has() { grep -qF -- "$2" <<<"$1"; }
check() { # check <name> <haystack> <needle>
  if has "$2" "$3"; then pass "$1"; else bad "$1 (missing: $3)"; fi
}
check_not() {
  if has "$2" "$3"; then bad "$1 (unexpected: $3)"; else pass "$1"; fi
}

# ---------- template ----------

tmpl > "$T/tmpl.yml" 2> "$T/tmpl.err"; rc=$?
[ "$rc" -eq 0 ] && pass "template exits 0" || bad "template exits 0 (rc=$rc: $(cat "$T/tmpl.err"))"
TM="$(cat "$T/tmpl.yml")"

check "template target and from" "$TM" 'target: "v1.1.0"'
check "template from" "$TM" 'from: "v1.0.0"'

"${PY[@]}" - "$T/tmpl.yml" > "$T/tmpl.facts" <<'PY'
import sys
import yaml
d = yaml.safe_load(open(sys.argv[1]))
cs = d["candidates"]
print("cands", [(c["kind"], c["commit"], c.get("feature", "-")) for c in cs])
print("c_verdicts", [c["verdict"] for c in cs])
print("c_reason", [c["reason"] for c in cs])
rows = d["upstream_priority"]
print("rows", [(r["kind"], r["id"]) for r in rows])
print("row_verdicts", sorted({(r["verdict"], r["evidence"], r["action"]) for r in rows}))
core = next(r for r in rows if r["id"] == "core-ours")
print("core_upstream", [(u["commit"], u["pr"]) for u in core["upstream"]])
print("core_cards", core["cards"], core["status"])
wake = next(r for r in rows if r["id"] == "wake-plan")
print("wake_upstream", [(u["commit"], u["pr"]) for u in wake["upstream"]])
quiet = next(r for r in rows if r["id"] == "quiet-ui")
print("quiet_upstream", quiet["upstream"])
c0 = cs[0]
print("c0", c0["pr"], c0["feature"], c0["cards"], c0["drop_when"], c0["evidence"])
PY
FACTS="$(cat "$T/tmpl.facts")"

check "template C entries then E not-already-C entries, short sha" "$FACTS" "cands [('C', 'aaaaaaaaa', 'core-ours'), ('C', 'bbbbbbbbb', 'wake-plan'), ('E', 'ccccccccc', '-')]"
check "template candidates start with empty verdict and reason" "$FACTS" "c_verdicts ['', '', '']"
check "template reasons empty" "$FACTS" "c_reason ['', '', '']"
check "template C entry carries pr, feature, cards, drop_when, evidence" "$FACTS" "c0 101 core-ours ['CALA-1'] upstream ships thing list ['PR #101이 레지스트리에 등록됨']"
check "template rows: active and planned features, then open cards outside the registry" "$FACTS" "rows [('feature', 'core-ours'), ('feature', 'wake-plan'), ('feature', 'quiet-ui'), ('card', 'CALA-7'), ('card', 'CALA-10')]"
check_not "template drops dropped features" "$TM" "gone-feature"
check "template rows start empty" "$FACTS" "row_verdicts [('', '', '')]"
check "template prefills upstream C commits for the feature" "$FACTS" "core_upstream [('aaaaaaaaa', 101)]"
check "template prefills upstream C commits for a planned feature" "$FACTS" "wake_upstream [('bbbbbbbbb', 102)]"
check "template leaves upstream empty without a C match" "$FACTS" "quiet_upstream []"
check "template carries registry cards and status" "$FACTS" "core_cards ['CALA-1', 'CALA-2'] active"
check_not "template folds a card already in the registry (open)" "$TM" 'id: "CALA-2"'
check_not "template folds a card already in the registry (done)" "$TM" "registered and done"
check_not "template skips a closed card outside the registry" "$TM" "CALA-8"
check_not "template skips a cancelled card" "$TM" "CALA-11"
check_not "template excludes the absorb card" "$TM" "CALA-99"

tmpl --exclude-card "" > /dev/null 2>&1 # empty value tolerated
run template --triage "$T/triage.json" --registry "$T/features.yml" --cards "$T/cards.json" > "$T/tmpl-noexcl.yml" 2>/dev/null
check "template without --exclude-card keeps the absorb card" "$(cat "$T/tmpl-noexcl.yml")" 'id: "CALA-99"'
run template --triage "$T/triage.json" --registry "$T/features.yml" --cards "$T/cards.json" --exclude-card CALA-7,CALA-10 > "$T/tmpl-multi.yml" 2>/dev/null
check_not "template exclude-card accepts a comma list" "$(cat "$T/tmpl-multi.yml")" 'id: "CALA-10"'
run template --triage "$T/triage.json" --registry "$T/features.yml" > "$T/tmpl-nocards.yml" 2>/dev/null
check_not "template without --cards has no card rows" "$(cat "$T/tmpl-nocards.yml")" "kind: card"

tmpl > "$T/tmpl2.yml" 2>/dev/null
cmp -s "$T/tmpl.yml" "$T/tmpl2.yml" && pass "template is deterministic" || bad "template is deterministic"

run template --triage "$T/missing.json" --registry "$T/features.yml" > "$T/o" 2> "$T/e"; rc=$?
{ [ "$rc" -eq 2 ] && [ ! -s "$T/o" ] && [ -s "$T/e" ]; } && pass "template missing triage exits 2" || bad "template missing triage exits 2 (rc=$rc)"
run template --triage "$T/triage.json" --registry "$T/nope.yml" > "$T/o" 2> "$T/e"; rc=$?
{ [ "$rc" -eq 2 ] && [ ! -s "$T/o" ]; } && pass "template missing registry exits 2" || bad "template missing registry exits 2 (rc=$rc)"

# ---------- comment: happy path ----------

fill "$T/tmpl.yml" "$GOOD"
cmt > "$T/c1.md" 2> "$T/c1.err"; rc=$?
[ "$rc" -eq 0 ] && pass "comment exits 0" || bad "comment exits 0 (rc=$rc: $(cat "$T/c1.err"))"
C1="$(cat "$T/c1.md")"
first="$(head -n1 "$T/c1.md")"
[ "$first" = "배포 준비 완료. 승인하면 배포합니다." ] && pass "comment first line is the conclusion" || bad "comment first line is the conclusion ($first)"
for h in '**요약**' '**상류 우선 판정**' '**C·E 후보 확정**' '**기능·화면 시험**' '**화면 비교**' '**승인하면 하는 일**'; do
  check "comment has section $h" "$C1" "$h"
done
check "comment range and commit count" "$C1" '`v1.0.0`에서 `v1.1.0`까지입니다. merge를 뺀 커밋은 4개입니다.'
check "comment conflict files" "$C1" '병합 충돌은 1파일입니다. `server/pkg/core.go`.'
check "comment migrations with range and irreversibility" "$C1" '마이그레이션은 2개입니다 (7~8). 적용하면 되돌릴 수 없어'
check "comment new env" "$C1" '`NEW_KEY`'
check "comment new cli" "$C1" '`thing list`'
check "comment priority table header" "$C1" '| 대상 | 판정 | 근거 | 할 일 |'
check "comment priority row with upstream pr" "$C1" '| `core-ours` (active) 상류 #101 | 상류 위에 남은 것만 | PR #101 본문, 시험 통과 | 없음 |'
check "comment card row" "$C1" '| CALA-7 open card outside the registry |'
check "comment candidates table header" "$C1" '| 커밋 | PR | 개조·영역 | 판정 | 이유 |'
check "comment C row" "$C1" '| `aaaaaaaaa` | [#101](https://github.com/multica-ai/multica/pull/101) | `core-ours` (CALA-1) | 줄임 | PR 본문 확인 |'
check "comment E row" "$C1" '| `ccccccccc` | [#103](https://github.com/multica-ai/multica/pull/103) | inbox | 흡수 | PR 본문 확인 |'
check "comment test table header" "$C1" '| 개조 | 판정 | 시험 | 시나리오 | 화면 |'
check "comment feature row with test and scenario counts" "$C1" '| `core-ours` | **통과** | 통과 1/1 | 통과 1/1 | - |'
check "comment screen row" "$C1" '| `quiet-ui` | **통과** | - | - | 통과 2/2 |'
check "comment n/a row" "$C1" '| `wake-plan` | **해당 없음** | - | 해당 없음 0/1 | - |'
check "comment totals line" "$C1" '합계 통과 4, 실패 0, 확인 불가 0, 해당 없음 1. fork-verify 종료 코드 0.'
check "comment screen section names the columns and files" "$C1" '운영 | 후보 | 차이'
check "comment steps: tag first" "$C1" '1. 병합 커밋에 `<tag>` 태그를 답니다.'
check "comment steps: backup, release, screen retest" "$C1" '2. 운영 DB를 `pg_dump`로 백업합니다.'
check "comment release step" "$C1" '3. `scripts/hoon/release.sh release <tag>`'
check "comment retest step" "$C1" '4. 운영에서 `scripts/hoon/fork-verify.sh <tag> --skip test,scenario`'
check "comment rollback line" "$C1" '이미지와 바이너리만 되돌립니다. 마이그레이션은 되돌리지 않습니다.'
check "comment single question" "$C1" 'Decide: 배포를 승인할까요?'
[ "$(grep -c '^Decide:' "$T/c1.md")" -eq 1 ] && pass "comment has exactly one question without 유지 rows" || bad "comment has exactly one question without 유지 rows"
check_not "comment has no em dash" "$C1" '—'

# Optional links and planned tag.
cmt --pr https://example.invalid/pr/1 --merge-commit "$SAMETREE" --pr-check https://example.invalid/chk --tag v1.1.0-hoon.1 > "$T/c-links.md" 2>/dev/null
CL="$(cat "$T/c-links.md")"
check "comment shows PR link" "$CL" 'https://example.invalid/pr/1'
check "comment shows merge commit" "$CL" "병합 커밋 \`$SAMETREE\`"
check "comment shows local check link" "$CL" 'https://example.invalid/chk'
check "comment uses the planned tag in the release step" "$CL" 'scripts/hoon/release.sh release v1.1.0-hoon.1'

# Attachments: delimiter, triage md first, regions then compare-only, absolute, capped.
att="$(sed -n '/^--- attachments$/,$p' "$T/c1.md" | tail -n +2)"
want="$T/triage.md
$T/fv-ok/screens/shot-1440.region.png
$T/fv-ok/screens/shot-700.compare.png
$T/fv-ok/screens/shot-900.region.png"
[ "$att" = "$want" ] && pass "comment attachments: triage md, region images, compare-only shots" || bad "comment attachments ($att)"
[ "$(grep -c '^--- attachments$' "$T/c1.md")" -eq 1 ] && pass "comment has one attachments delimiter" || bad "comment has one attachments delimiter"
case "$att" in *prod.png*|*cand.png*|*shot-1440.compare.png*|*shot-900.compare.png*) bad "comment attaches only region or compare-only images" ;; *) pass "comment attaches only region or compare-only images" ;; esac

mkdir -p "$T/fv-many/screens"
cp "$T/fv-ok/result.json" "$T/fv-many/"
for i in 1 2 3 4 5 6 7 8 9 10; do : > "$T/fv-many/screens/s$i.region.png"; done
FV="$T/fv-many" cmt > "$T/c-many.md" 2>/dev/null
[ "$(sed -n '/^--- attachments$/,$p' "$T/c-many.md" | tail -n +2 | wc -l | tr -d ' ')" -eq 8 ] && pass "comment caps attachments at 8 including the triage md" || bad "comment caps attachments at 8"
check "comment says how many captures were left out" "$(cat "$T/c-many.md")" '나머지 3장은 fork-verify 출력 폴더에 있습니다.'

cmt > "$T/c1b.md" 2>/dev/null
cmp -s "$T/c1.md" "$T/c1b.md" && pass "comment is deterministic" || bad "comment is deterministic"

# ---------- comment: hold conditions ----------

FV="$T/fv-fail" cmt > "$T/c-fail.md" 2> "$T/c-fail.err"; rc=$?
[ "$rc" -eq 0 ] && pass "comment with a fork-verify failure still exits 0" || bad "comment with a fork-verify failure exits 0 (rc=$rc)"
first="$(head -n1 "$T/c-fail.md")"
case "$first" in "배포 보류: "*"fork-verify 실패 1건"*) pass "comment holds on a fork-verify failure" ;; *) bad "comment holds on a fork-verify failure ($first)" ;; esac
check "comment lists the failed check" "$(cat "$T/c-fail.md")" '`core-ours` 실패 does the thing. detail-of-scenario'
check "comment failure totals" "$(cat "$T/c-fail.md")" '합계 통과 3, 실패 1, 확인 불가 0, 해당 없음 1. fork-verify 종료 코드 1.'
check "comment failure feature row" "$(cat "$T/c-fail.md")" '| `core-ours` | **실패** | 통과 1/1 | 실패 0/1 | - |'

FV="$T/fv-unverified" cmt > "$T/c-unv.md" 2>/dev/null
first="$(head -n1 "$T/c-unv.md")"
case "$first" in "배포 보류: "*"확인 불가 1건"*) pass "comment holds on an unverified item" ;; *) bad "comment holds on an unverified item ($first)" ;; esac
check "comment unverified feature row" "$(cat "$T/c-unv.md")" '| `core-ours` | **확인 불가** | 통과 1/1 | 확인 불가 0/1 | - |'

# 우리 것 유지 rows: hold, one question each; confirmed rows ask nothing.
"${PY[@]}" - "$GOOD" "$T/keep.yml" "$T/keep-confirmed.yml" <<'PY'
import sys
import yaml
d = yaml.safe_load(open(sys.argv[1]))
for r in d["upstream_priority"]:
    if r["id"] in ("quiet-ui", "CALA-7"):
        r["verdict"] = "우리 것 유지"
yaml.safe_dump(d, open(sys.argv[2], "w"), allow_unicode=True, sort_keys=False)
for r in d["upstream_priority"]:
    if r["verdict"] == "우리 것 유지":
        r["confirmed"] = True
yaml.safe_dump(d, open(sys.argv[3], "w"), allow_unicode=True, sort_keys=False)
PY
DEC="$T/keep.yml" cmt > "$T/c-keep.md" 2>/dev/null; rc=$?
[ "$rc" -eq 0 ] && pass "comment with 유지 rows exits 0" || bad "comment with 유지 rows exits 0 (rc=$rc)"
first="$(head -n1 "$T/c-keep.md")"
case "$first" in "배포 보류: 우리 것 유지 2건 확인 필요") pass "comment holds on 우리 것 유지 rows" ;; *) bad "comment holds on 우리 것 유지 rows ($first)" ;; esac
[ "$(grep -c '^Decide:' "$T/c-keep.md")" -eq 3 ] && pass "comment asks one extra question per 유지 row" || bad "comment asks one extra question per 유지 row"
check "comment names the 유지 row in its question" "$(cat "$T/c-keep.md")" 'Decide: `quiet-ui` 건은 우리 것을 그대로 유지할까요?'
DEC="$T/keep-confirmed.yml" cmt > "$T/c-keepok.md" 2>/dev/null
first="$(head -n1 "$T/c-keepok.md")"
[ "$first" = "배포 준비 완료. 승인하면 배포합니다." ] && pass "confirmed 유지 rows do not hold the deploy" || bad "confirmed 유지 rows do not hold the deploy ($first)"

# 상류에 없음: allowed, never holds the deploy and asks nothing.
"${PY[@]}" - "$GOOD" "$T/none.yml" <<'PY'
import sys
import yaml
d = yaml.safe_load(open(sys.argv[1]))
for r in d["upstream_priority"]:
    r["verdict"] = "상류에 없음"
yaml.safe_dump(d, open(sys.argv[2], "w"), allow_unicode=True, sort_keys=False)
PY
DEC="$T/none.yml" cmt > "$T/c-none.md" 2>/dev/null; rc=$?
first="$(head -n1 "$T/c-none.md")"
[ "$rc" -eq 0 ] && [ "$first" = "배포 준비 완료. 승인하면 배포합니다." ] && pass "상류에 없음 rows are accepted and do not hold" || bad "상류에 없음 rows are accepted and do not hold (rc=$rc, $first)"
[ "$(grep -c '^Decide:' "$T/c-none.md")" -eq 1 ] && pass "상류에 없음 rows ask nothing" || bad "상류에 없음 rows ask nothing"

# ---------- comment: validation (exit 2, nothing on stdout) ----------

expect2() { # expect2 <name> <stderr needle>; stdout/stderr files from the last call in $T/o, $T/e
  local name="$1" needle="$2" rc="$3"
  if [ "$rc" -ne 2 ]; then bad "$name (rc=$rc, want 2)"; return; fi
  if [ -s "$T/o" ]; then bad "$name (stdout not empty)"; return; fi
  if ! grep -qF -- "$needle" "$T/e"; then bad "$name (stderr lacks: $needle; got: $(cat "$T/e"))"; return; fi
  pass "$name"
}

"${PY[@]}" - "$GOOD" "$T/empty-c.yml" "$T/bad-c.yml" "$T/empty-row.yml" "$T/bad-row.yml" "$T/no-ev.yml" "$T/missing-e.yml" "$T/bad-e.yml" "$T/wrong-target.yml" "$T/no-reason-e.yml" "$T/no-reason-c.yml" <<'PY'
import copy
import sys
import yaml
d = yaml.safe_load(open(sys.argv[1]))
out = sys.argv[2:]

def save(path, doc):
    yaml.safe_dump(doc, open(path, "w"), allow_unicode=True, sort_keys=False)

x = copy.deepcopy(d); x["candidates"][0]["verdict"] = ""; save(out[0], x)
x = copy.deepcopy(d); x["candidates"][0]["verdict"] = "삭제"; save(out[1], x)
x = copy.deepcopy(d); x["upstream_priority"][1]["verdict"] = ""; save(out[2], x)
x = copy.deepcopy(d); x["upstream_priority"][2]["verdict"] = "모르겠음"; save(out[3], x)
x = copy.deepcopy(d); x["upstream_priority"][0]["evidence"] = ""; save(out[4], x)
x = copy.deepcopy(d); x["candidates"] = [c for c in x["candidates"] if c["kind"] != "E"]; save(out[5], x)
x = copy.deepcopy(d); [c.update(verdict="버림") for c in x["candidates"] if c["kind"] == "E"]; save(out[6], x)
x = copy.deepcopy(d); x["target"] = "v9.9.9"; save(out[7], x)
x = copy.deepcopy(d); [c.update(reason="  ") for c in x["candidates"] if c["kind"] == "E"]; save(out[8], x)
x = copy.deepcopy(d); [c.update(reason="") for c in x["candidates"] if c["kind"] == "C"][:1]; save(out[9], x)
PY

DEC="$T/empty-c.yml" cmt > "$T/o" 2> "$T/e"; expect2 "empty candidate verdict exits 2" "candidates aaaaaaaaa core-ours verdict가 비어 있습니다" $?
DEC="$T/bad-c.yml" cmt > "$T/o" 2> "$T/e"; expect2 "invalid candidate verdict exits 2" "verdict '삭제'는 허용 값이 아닙니다 (버림|줄임|유지)" $?
DEC="$T/empty-row.yml" cmt > "$T/o" 2> "$T/e"; expect2 "empty priority verdict exits 2" "upstream_priority wake-plan verdict가 비어 있습니다" $?
DEC="$T/bad-row.yml" cmt > "$T/o" 2> "$T/e"; expect2 "invalid priority verdict exits 2" "upstream_priority quiet-ui verdict '모르겠음'" $?
DEC="$T/no-ev.yml" cmt > "$T/o" 2> "$T/e"; expect2 "empty evidence exits 2" "upstream_priority core-ours evidence가 비어 있습니다" $?
DEC="$T/missing-e.yml" cmt > "$T/o" 2> "$T/e"; expect2 "missing E candidate exits 2" "candidates에 E 항목이 없습니다 (ccccccccc)" $?
DEC="$T/bad-e.yml" cmt > "$T/o" 2> "$T/e"; expect2 "E candidate with a C-only verdict exits 2" "verdict '버림'는 허용 값이 아닙니다 (흡수|보류|무관)" $?
DEC="$T/wrong-target.yml" cmt > "$T/o" 2> "$T/e"; expect2 "decisions for another range exit 2" "target/from이 triage와 다릅니다" $?
DEC="$T/no-reason-e.yml" cmt > "$T/o" 2> "$T/e"; expect2 "an E candidate without a reason exits 2" "candidates ccccccccc E reason이 비어 있습니다" $?
DEC="$T/no-reason-c.yml" cmt > "$T/o" 2> "$T/e"; expect2 "a C candidate without a reason exits 2" "candidates aaaaaaaaa core-ours reason이 비어 있습니다" $?

# Inventory coverage: the decisions must hold exactly one row per active/planned
# feature and per open card outside the registry.
"${PY[@]}" - "$GOOD" "$T/cov-empty.yml" "$T/cov-missing-card.yml" "$T/cov-missing-feature.yml" "$T/cov-dup.yml" "$T/cov-unknown.yml" "$T/cov-closed.yml" <<'PY'
import copy
import sys
import yaml
d = yaml.safe_load(open(sys.argv[1]))
out = sys.argv[2:]

def save(path, doc):
    yaml.safe_dump(doc, open(path, "w"), allow_unicode=True, sort_keys=False)

x = copy.deepcopy(d); x["upstream_priority"] = []; save(out[0], x)
x = copy.deepcopy(d); x["upstream_priority"] = [r for r in x["upstream_priority"] if r["id"] != "CALA-7"]; save(out[1], x)
x = copy.deepcopy(d); x["upstream_priority"] = [r for r in x["upstream_priority"] if r["id"] != "quiet-ui"]; save(out[2], x)
x = copy.deepcopy(d); x["upstream_priority"].append(copy.deepcopy(x["upstream_priority"][0])); save(out[3], x)
x = copy.deepcopy(d); r = copy.deepcopy(x["upstream_priority"][0]); r["id"] = "made-up"; x["upstream_priority"].append(r); save(out[4], x)
x = copy.deepcopy(d); r = copy.deepcopy(x["upstream_priority"][0]); r["id"] = "CALA-8"; x["upstream_priority"].append(r); save(out[5], x)
PY
DEC="$T/cov-empty.yml" cmt > "$T/o" 2> "$T/e"; expect2 "upstream_priority: [] is refused (rows deleted)" "upstream_priority에 행이 없습니다 (core-ours)" $?
check "emptied upstream_priority lists every missing id" "$(cat "$T/e")" "upstream_priority에 행이 없습니다 (CALA-10)"
DEC="$T/cov-missing-card.yml" cmt > "$T/o" 2> "$T/e"; expect2 "a deleted open-card row is refused" "upstream_priority에 행이 없습니다 (CALA-7)" $?
DEC="$T/cov-missing-feature.yml" cmt > "$T/o" 2> "$T/e"; expect2 "a deleted feature row is refused" "upstream_priority에 행이 없습니다 (quiet-ui)" $?
DEC="$T/cov-dup.yml" cmt > "$T/o" 2> "$T/e"; expect2 "a duplicate row is refused" "upstream_priority에 id가 2번 있습니다 (core-ours)" $?
DEC="$T/cov-unknown.yml" cmt > "$T/o" 2> "$T/e"; expect2 "an unknown id is refused" "upstream_priority에 알 수 없는 id가 있습니다 (made-up)" $?
DEC="$T/cov-closed.yml" cmt > "$T/o" 2> "$T/e"; expect2 "a row for a closed card is refused as unknown" "upstream_priority에 알 수 없는 id가 있습니다 (CALA-8)" $?

# An incomplete cards page cannot define the inventory.
sed 's/"has_more": false/"has_more": true/' "$T/cards.json" > "$T/cards-more.json"
CARDS="$T/cards-more.json" cmt > "$T/o" 2> "$T/e"; expect2 "comment refuses a cards page with has_more true" "has_more: true" $?
run template --triage "$T/triage.json" --registry "$T/features.yml" --cards "$T/cards-more.json" > "$T/o" 2> "$T/e"; expect2 "template refuses a cards page with has_more true" "has_more: true" $?
run comment --triage "$T/triage.json" --decisions "$GOOD" --verify "$T/fv-ok" --registry "$T/features.yml" --candidate "$CAND" > "$T/o" 2> "$T/e"; rc=$?
[ "$rc" -eq 2 ] && [ ! -s "$T/o" ] && pass "comment without --cards exits 2" || bad "comment without --cards exits 2 (rc=$rc)"
run comment --triage "$T/triage.json" --decisions "$GOOD" --verify "$T/fv-ok" --registry "$T/nope.yml" --cards "$T/cards.json" --candidate "$CAND" > "$T/o" 2> "$T/e"; expect2 "comment with an unreadable registry exits 2" "레지스트리를 읽을 수 없습니다" $?

# ---------- comment: the verification is bound to the candidate ----------

# result.json for another commit: refuse, nothing on stdout.
CANDIDATE="$OTHERTREE" cmt > "$T/o" 2> "$T/e"; expect2 "result.json sha != --candidate exits 2" "후보와 다른 커밋을 검증했습니다" $?
CANDIDATE="no-such-rev" cmt > "$T/o" 2> "$T/e"; expect2 "unknown --candidate rev exits 2" "--candidate를 찾을 수 없습니다" $?
run comment --triage "$T/triage.json" --decisions "$GOOD" --verify "$T/fv-ok" --registry "$T/features.yml" --cards "$T/cards.json" --exclude-card CALA-99 > "$T/o" 2> "$T/e"; rc=$?
[ "$rc" -eq 2 ] && [ ! -s "$T/o" ] && pass "comment without --candidate exits 2" || bad "comment without --candidate exits 2 (rc=$rc)"
(cd "$T" && bash "$SCRIPT" comment --triage "$T/triage.json" --decisions "$GOOD" --verify "$T/fv-ok" --registry "$T/features.yml" --cards "$T/cards.json" --exclude-card CALA-99 --candidate "$CAND") > "$T/o" 2> "$T/e"; expect2 "--candidate outside a git repository exits 2" "git 저장소 안에서" $?
sed "s/$CAND/${CAND:0:12}/" "$T/fv-ok/result.json" > "$T/short-sha.json"; mkdir -p "$T/fv-short" && cp "$T/short-sha.json" "$T/fv-short/result.json"
FV="$T/fv-short" cmt > "$T/o" 2> "$T/e"; expect2 "an abbreviated result.json sha does not match" "후보와 다른 커밋을 검증했습니다" $?

# --merge-commit: same tree is fine, another tree holds the deploy.
cmt --merge-commit "$SAMETREE" > "$T/c-mc-same.md" 2>/dev/null; rc=$?
first="$(head -n1 "$T/c-mc-same.md")"
[ "$rc" -eq 0 ] && [ "$first" = "배포 준비 완료. 승인하면 배포합니다." ] && pass "merge commit with the candidate's tree does not hold" || bad "merge commit with the candidate's tree does not hold (rc=$rc, $first)"
check "comment shows the verified candidate" "$(cat "$T/c-mc-same.md")" "검증한 후보 \`$CAND\`"
cmt --merge-commit "$CAND" > "$T/c-mc-self.md" 2>/dev/null
[ "$(head -n1 "$T/c-mc-self.md")" = "배포 준비 완료. 승인하면 배포합니다." ] && pass "merge commit equal to the candidate does not hold" || bad "merge commit equal to the candidate does not hold"
cmt --merge-commit "$OTHERTREE" > "$T/c-mc-diff.md" 2> "$T/e"; rc=$?
first="$(head -n1 "$T/c-mc-diff.md")"
[ "$rc" -eq 0 ] && case "$first" in "배포 보류: "*"검증한 트리와 병합 커밋이 다름"*) true ;; *) false ;; esac && pass "merge commit with another tree holds the deploy" || bad "merge commit with another tree holds the deploy (rc=$rc, $first)"
cmt --merge-commit "no-such-rev" > "$T/o" 2> "$T/e"; expect2 "unknown --merge-commit rev exits 2" "--merge-commit를 찾을 수 없습니다" $?

# Every active registry feature needs a check in result.json; empty checks hold.
mkdir -p "$T/fv-missing-feat" "$T/fv-empty"
"${PY[@]}" - "$T/fv-ok/result.json" "$T/fv-missing-feat/result.json" "$T/fv-empty/result.json" <<'PY'
import json
import sys
d = json.load(open(sys.argv[1]))
x = dict(d); x["checks"] = [c for c in d["checks"] if c["feature"] != "quiet-ui"]
json.dump(x, open(sys.argv[2], "w"))
x = dict(d); x["checks"] = []
json.dump(x, open(sys.argv[3], "w"))
PY
FV="$T/fv-missing-feat" cmt > "$T/c-missfeat.md" 2> "$T/e"; rc=$?
first="$(head -n1 "$T/c-missfeat.md")"
[ "$rc" -eq 0 ] && case "$first" in "배포 보류: "*"검증 결과에 없는 개조 1건"*"quiet-ui"*) true ;; *) false ;; esac && pass "an active feature without a check holds the deploy" || bad "an active feature without a check holds the deploy (rc=$rc, $first)"
FV="$T/fv-empty" cmt > "$T/c-empty.md" 2> "$T/e"; rc=$?
first="$(head -n1 "$T/c-empty.md")"
[ "$rc" -eq 0 ] && case "$first" in "배포 보류: "*"검증 결과가 비어 있음"*"검증 결과에 없는 개조 2건"*) true ;; *) false ;; esac && pass "empty checks hold the deploy" || bad "empty checks hold the deploy (rc=$rc, $first)"
FV="$T/fv-ok" cmt > "$T/c-allfeat.md" 2>/dev/null
[ "$(head -n1 "$T/c-allfeat.md")" = "배포 준비 완료. 승인하면 배포합니다." ] && pass "a planned feature and an n/a check do not need more coverage" || bad "n/a check for the planned feature is enough"

# --registry-ref reads the registry from git, like template.
mkdir -p "$G/fork" && cp "$T/features.yml" "$G/fork/features.yml" && git -C "$G" add -A && git -C "$G" commit -qm registry && REGREF="$(git -C "$G" rev-parse HEAD)"
git -C "$G" reset -q --hard "$OTHERTREE"
cmt --registry "fork/features.yml" --registry-ref "$REGREF" > "$T/c-regref.md" 2> "$T/e"; rc=$?
[ "$rc" -eq 0 ] && [ "$(head -n1 "$T/c-regref.md")" = "배포 준비 완료. 승인하면 배포합니다." ] && pass "comment reads the registry at --registry-ref" || bad "comment reads the registry at --registry-ref (rc=$rc: $(cat "$T/e"))"

# The unfilled template itself must be refused, naming every entry.
run comment --triage "$T/triage.json" --decisions "$T/tmpl.yml" --verify "$T/fv-ok" --registry "$T/features.yml" --cards "$T/cards.json" --exclude-card CALA-99 --candidate "$CAND" > "$T/o" 2> "$T/e"; rc=$?
expect2 "unfilled template exits 2" "decisions가 완성되지 않았습니다" "$rc"
n="$(grep -c 'verdict가 비어 있습니다' "$T/e")"
[ "$n" -eq 8 ] && pass "unfilled template reports every empty entry (8)" || bad "unfilled template reports every empty entry (got $n)"

# Bad inputs.
run comment --triage "$T/triage.json" --decisions "$T/nope.yml" --verify "$T/fv-ok" --registry "$T/features.yml" --cards "$T/cards.json" --exclude-card CALA-99 --candidate "$CAND" > "$T/o" 2> "$T/e"; expect2 "missing decisions exits 2" "decisions를 읽을 수 없습니다" $?
run comment --triage "$T/triage.json" --decisions "$GOOD" --verify "$T/nope" --registry "$T/features.yml" --cards "$T/cards.json" --exclude-card CALA-99 --candidate "$CAND" > "$T/o" 2> "$T/e"; expect2 "missing fork-verify dir exits 2" "fork-verify 결과가 없습니다" $?
printf '{bad' > "$T/badjson"
run comment --triage "$T/badjson" --decisions "$GOOD" --verify "$T/fv-ok" --registry "$T/features.yml" --cards "$T/cards.json" --exclude-card CALA-99 --candidate "$CAND" > "$T/o" 2> "$T/e"; expect2 "broken triage JSON exits 2" "JSON이 아닙니다" $?
run comment --triage "$T/triage.json" --decisions "$GOOD" --verify "$T/fv-ok" --triage-md "$T/nope.md" --registry "$T/features.yml" --cards "$T/cards.json" --exclude-card CALA-99 --candidate "$CAND" > "$T/o" 2> "$T/e"; expect2 "missing triage md exits 2" "triage 마크다운을 읽을 수 없습니다" $?
run comment --triage "$T/triage.json" --decisions "$GOOD" > "$T/o" 2> "$T/e"; rc=$?
[ "$rc" -eq 2 ] && [ ! -s "$T/o" ] && pass "missing --verify exits 2" || bad "missing --verify exits 2 (rc=$rc)"
run bogus > "$T/o" 2> "$T/e"; rc=$?
[ "$rc" -eq 2 ] && pass "unknown subcommand exits 2" || bad "unknown subcommand exits 2 (rc=$rc)"

exit "$fail"

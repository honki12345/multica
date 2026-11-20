#!/usr/bin/env bash
# Local PR check gate for the honki12345/multica fork (AGENTS.md "Fork rules",
# FORK.md "Verification"). The fork does not use GitHub Actions; this script is
# the merge gate.
#
#   scripts/hoon/fork-pr-check.sh run  <PR#> [--post] [--repo <owner/name>] [--out <dir>] [--base <rev>]
#   scripts/hoon/fork-pr-check.sh plan <PR#> [--repo <owner/name>] [--base <rev>]
#   scripts/hoon/fork-pr-check.sh gate <PR#> [--repo <owner/name>]
#
# run   Fetches the PR head into refs/fork-pr-check/<n>, checks it out in a
#       clean detached worktree under ${TMPDIR:-/tmp}, runs the checks that the
#       changed files call for, and prints a Korean PR comment body (head SHA,
#       base, machine, per-command exit code/result/time, verdict, machine
#       marker). With --post the body is also posted with `gh pr comment`.
#       Full logs go to --out (default out/fork-pr-check/<n>-<sha7>/ under the
#       checkout the script runs in). The worktree is always removed.
#       Exit 0: all checks passed; 1: a check failed; 2: setup error (gh/git
#       failed, head moved while fetching, post failed).
# plan  Prints the commands `run` would execute, one per line, and runs nothing.
# gate  Reads the PR comments and takes the newest valid one (only from
#       OWNER/MEMBER/COLLABORATOR; a stranger's comment cannot open the gate).
#       Valid means the body is what `run` generates: the first line is
#       `## 로컬 검사 (fork-pr-check)`, a line ``- head: `<sha>` `` carries the
#       same sha as the marker, and the marker
#       `<!-- fork-pr-check pr=<n> head=<sha> verdict=pass|fail -->` is the
#       last non-empty line. The header, head line, table rows and marker must
#       start at column 0 (the generator never indents them) and sit outside
#       every code fence (CommonMark: 3+ backticks or tildes, closed only by the
#       same char at least as long); quoted, fenced or indented copies do not
#       count. verdict=pass also needs table rows for license-check.sh and
#       features-check.sh with exit code 0 and no row with a non-zero exit code,
#       so a hand-edited verdict cannot pass. An invalid newer comment is
#       ignored, not a blocker. It prints `gate=ok head=<sha>` (exit 0) only when that head is the PR's
#       current head and the verdict is pass. Otherwise prints
#       `gate=blocked reason=no-comment|head-moved|verdict-fail` (exit 1).
#       Exit 2 (`gate=error`) when gh fails. Merge only after gate=ok:
#         gh pr merge <n> --merge --match-head-commit <sha from gate=ok>
#
# Check selection (from the files changed between merge-base(base, head) and
# head; deleted files count, see below):
#   always            license-check.sh, features-check.sh, git diff --check
#   scripts/hoon/X*   scripts/hoon/X.test.sh when it exists at head; shellcheck
#                     -S warning on the changed scripts/hoon .sh files that
#                     still exist
#   fork/features.yml features-check.test.sh
#   .github/**, scripts/*.mjs   node --test scripts/ci-scope.test.mjs
#   server/go.mod, go.sum   cd server && go build ./... && go vet ./cmd/...
#                     ./internal/... ./pkg/... (never the full go test)
#   server/**/*.go    cd server && go test -p 2 <changed package dirs>; a
#                     deleted Go file selects its dir when that dir still has Go
#                     files at head, else the module build above
#   apps|packages TS, pnpm-lock.yaml, pnpm-workspace.yaml, package.json,
#   tsconfig*.json, turbo.json (root/apps/packages, not apps/mobile)
#                     pnpm install, pnpm typecheck, and per package vitest
#                     related <changed files that still exist> (skipped when
#                     none; never a full vitest run)
# Checks run with DATABASE_URL/DIRECT_URL/TEST_DATABASE_URL unset, so DB-backed Go
# tests skip; no database is started.
#
# --base <rev> replaces the base commit (default: tip of the PR's base branch).
# Use it to dry-run an already merged PR, whose head is contained in the base
# tip so that no files differ: --base <first parent of the merge commit>.
#
# Test overrides (no network): FPC_GH=<gh binary or stub> (default gh),
# --repo-url <git url> (default https://github.com/<repo>.git),
# --upstream-url <git url> (default https://github.com/multica-ai/multica.git).
set -uo pipefail

GH="${FPC_GH:-gh}"
REPO=honki12345/multica
REPO_URL=""
UPSTREAM_URL=https://github.com/multica-ai/multica.git
OUT=""
BASE_REV=""
POST=0
PR=""

usage() {
  echo "usage: $0 run|plan|gate <PR#> [--post] [--repo <owner/name>] [--out <dir>] [--base <rev>] [--repo-url <url>] [--upstream-url <url>]" >&2
  exit 2
}
die() { echo "fork-pr-check: $1" >&2; exit 2; }

g() {
  git -c core.attributesFile= -c core.quotePath=false -c diff.external= -c diff.noprefix=false \
    -c diff.mnemonicPrefix=false -c color.ui=false -c color.diff=false -c log.showSignature=false "$@"
}

[ $# -ge 2 ] || usage
CMD="$1"; shift
case "$CMD" in run|plan|gate) ;; *) usage ;; esac
PR="$1"; shift
case "$PR" in ''|*[!0-9]*) usage ;; esac
while [ $# -gt 0 ]; do
  case "$1" in
    --post) POST=1; shift ;;
    --repo) [ $# -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --out) [ $# -ge 2 ] || usage; OUT="$2"; shift 2 ;;
    --base) [ $# -ge 2 ] || usage; BASE_REV="$2"; shift 2 ;;
    --repo-url) [ $# -ge 2 ] || usage; REPO_URL="$2"; shift 2 ;;
    --upstream-url) [ $# -ge 2 ] || usage; UPSTREAM_URL="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$REPO_URL" ] || REPO_URL="https://github.com/$REPO.git"
case "$OUT" in ''|/*) ;; *) OUT="$PWD/$OUT" ;; esac

IFS= read -r -d '' PRVIEW_PY <<'PY'
import json, re, sys
d = json.load(sys.stdin)
oid, ref, base, url = d["headRefOid"], d["headRefName"], d["baseRefName"], d["url"]
if not re.fullmatch(r"[0-9a-f]{40}", oid):
    sys.exit("headRefOid is not a 40-char sha: %r" % oid)
if not re.fullmatch(r"[A-Za-z0-9._/-]+", base):
    sys.exit("unexpected base ref name: %r" % base)
print("\t".join((oid, ref, base, url)))
PY

IFS= read -r -d '' GATE_PY <<'PY'
import json, re, sys
n, cur = sys.argv[1], sys.argv[2]
text = sys.stdin.read()
dec, i, items = json.JSONDecoder(), 0, []
while True:
    while i < len(text) and text[i].isspace():
        i += 1
    if i >= len(text):
        break
    v, i = dec.raw_decode(text, i)
    items.extend(v if isinstance(v, list) else [v])

HEADER = "## 로컬 검사 (fork-pr-check)"
MARK = re.compile(r"^<!-- fork-pr-check pr=(\d+) head=([0-9a-f]{40}) verdict=(pass|fail) -->$")
HEAD = re.compile(r"^- head: `([0-9a-f]{40})`$")
ROW = re.compile(r"^\| `(.+?)` \| (\d+) \| ")
TABLE_HEAD = "| 명령 | 종료 코드 | 결과 | 시간 |"
TABLE_SEP = "|---|---|---|---|"
ROW_FULL = re.compile(r"^\| `(.+?)` \| (\d+) \| .* \| \d+s \|$")
TRAILER = {"전체 시험은 출시 CI에서 돈다(포크 규칙: 전체 vitest run 금지)",
           "Go 시험은 DATABASE_URL 없이 돌려서 DB가 필요한 시험은 skip된다(이 Mac에 DB를 띄우지 않음)."}
REQUIRED = ("bash scripts/hoon/license-check.sh", "bash scripts/hoon/features-check.sh")


def parse(body):
    """(head, verdict) of a comment laid out exactly as the generator writes it, else None.

    The layout is fixed line by line (header, PR/head/base/machine/time lines,
    the table, the verdict line, the fixed trailer, the marker last). Any other
    line (HTML, quote, code block, prose) breaks the layout, so evidence cannot
    be hidden inside Markdown that renders differently.
    """
    lines = [l.rstrip("\r") for l in body.split("\n")]
    while lines and not lines[-1].strip():
        lines.pop()
    if len(lines) < 14 or lines[0] != HEADER or lines[1] != "" or lines[7] != "":
        return None
    if not lines[2].startswith("- PR: #%s (" % n):
        return None
    h = HEAD.match(lines[3])
    if not h or not lines[4].startswith("- base: `") or not lines[5].startswith("- 기기: ") \
            or not lines[6].startswith("- 시각(UTC): "):
        return None
    if lines[8] != TABLE_HEAD or lines[9] != TABLE_SEP:
        return None
    k, rows = 10, []
    while k < len(lines) and lines[k] != "":
        r = ROW_FULL.match(lines[k])
        if not r:
            return None
        rows.append((r.group(1).replace("\\|", "|"), int(r.group(2))))
        k += 1
    if not rows or k + 1 >= len(lines) or not lines[k + 1].startswith("판정: "):
        return None
    m = MARK.match(lines[-1])
    if not m or m.group(1) != n or m.group(2) != h.group(1):
        return None
    if any(l and l not in TRAILER for l in lines[k + 2:-1]):
        return None
    if m.group(3) == "pass":
        ok = {c for c, rc in rows if rc == 0}
        if lines[k + 1] != "판정: 통과 (실패 0)" or any(rc != 0 for _, rc in rows) \
                or not all(r in ok for r in REQUIRED):
            return None
    return m.group(2), m.group(3)


best = None
for c in items:
    if not isinstance(c, dict) or c.get("author_association") not in ("OWNER", "MEMBER", "COLLABORATOR"):
        continue
    got = parse(c.get("body") or "")
    if got is None:
        continue
    key = (c.get("created_at") or "", c.get("id") or 0)
    if best is None or key > best[0]:
        best = (key, got[0], got[1])
if best is None:
    print("gate=blocked reason=no-comment"); sys.exit(1)
_, head, verdict = best
if head != cur:
    print("gate=blocked reason=head-moved"); sys.exit(1)
if verdict != "pass":
    print("gate=blocked reason=verdict-fail"); sys.exit(1)
print("gate=ok head=" + head)
PY

IFS= read -r -d '' PLAN_PY <<'PY'
import json, os, shlex, subprocess, sys

sha, mergebase = sys.argv[1], sys.argv[2]
tok = [t for t in sys.stdin.buffer.read().decode("utf-8", "replace").split("\0") if t]
changed = dict((tok[i + 1], tok[i][0]) for i in range(0, len(tok) - 1, 2))
files = sorted(changed)
alive = [f for f in files if changed[f] != "D"]
q = shlex.quote


def git(*a):
    return subprocess.run(["git", "-c", "core.quotePath=false", *a], capture_output=True, text=True)


def exists(path):
    return git("cat-file", "-e", f"{sha}:{path}").returncode == 0


def has_go(d):
    return any(n.endswith(".go") for n in git("ls-tree", "--name-only", f"{sha}:{d}" if d else sha).stdout.split("\n"))


cmds = [
    "bash scripts/hoon/license-check.sh",
    "bash scripts/hoon/features-check.sh",
    f"git diff --check {mergebase}..HEAD",
]

HOON = "scripts/hoon/"
names, shells = set(), []
for f in files:
    if not f.startswith(HOON):
        continue
    rest = f[len(HOON):]
    if "/" in rest:
        names.add(rest.split("/")[0])
    elif rest.endswith(".test.sh"):
        names.add(rest[: -len(".test.sh")])
    elif rest.endswith(".sh"):
        names.add(rest[: -len(".sh")])
    if f.endswith(".sh") and f in alive:
        shells.append(f)
for name in sorted(names):
    t = f"{HOON}{name}.test.sh"
    if exists(t):
        cmds.append(f"bash {t}")
if shells:
    cmds.append("shellcheck -S warning " + " ".join(q(f) for f in sorted(shells)))

if "fork/features.yml" in files:
    cmds.append("bash scripts/hoon/features-check.test.sh")

ci_scope = "scripts/ci-scope.test.mjs"
if any(f.startswith(".github/") or (f.startswith("scripts/") and f.endswith(".mjs") and f.count("/") == 1) for f in files):
    cmds.append(f"node --test {ci_scope}")

GO_MODULE = "cd server && go build ./... && go vet ./cmd/... ./internal/... ./pkg/..."
go_files = [f for f in files if f.startswith("server/") and f.endswith(".go")]
go_dirs, module_build = set(), any(f in ("server/go.mod", "server/go.sum") for f in files)
for f in go_files:
    d = os.path.dirname(f)
    if has_go(d):
        go_dirs.add("./" + d[len("server/"):] if d != "server" else ".")
    else:
        module_build = True
if module_build:
    cmds.append(GO_MODULE)
if go_dirs:
    cmds.append("cd server && go test -p 2 " + " ".join(q(d) for d in sorted(go_dirs)))


def js_scope(f):
    return not f.startswith("apps/mobile/") and (f.startswith(("apps/", "packages/")) or "/" not in f)


def js_config(f):
    base = os.path.basename(f)
    if not js_scope(f):
        return False
    if "/" not in f and base in ("pnpm-lock.yaml", "pnpm-workspace.yaml"):
        return True
    return base in ("package.json", "turbo.json") or (base.startswith("tsconfig") and base.endswith(".json"))


ts = [f for f in files if f.endswith((".ts", ".tsx")) and f.startswith(("apps/", "packages/")) and not f.startswith("apps/mobile/")]
if ts or any(js_config(f) for f in files):
    cmds += ["pnpm install --frozen-lockfile --prefer-offline", "pnpm typecheck"]
    by_pkg = {}
    for f in ts:
        if f not in alive:
            continue
        d = os.path.dirname(f)
        while d and not exists(d + "/package.json"):
            d = os.path.dirname(d)
        if d:
            by_pkg.setdefault(d, []).append(f[len(d) + 1:])
    for d in sorted(by_pkg):
        pj = json.loads(git("show", f"{sha}:{d}/package.json").stdout)
        deps = {**pj.get("dependencies", {}), **pj.get("devDependencies", {})}
        if "vitest" in deps:
            rel = " ".join(q(f) for f in sorted(by_pkg[d]))
            cmds.append(f"pnpm --filter {q(pj['name'])} exec vitest related {rel} --run --maxWorkers=2")

seen = set()
for c in cmds:
    if c not in seen:
        seen.add(c)
        print(c)
PY

IFS= read -r -d '' BODY_PY <<'PY'
import re, sys

pr, sha, branch, url, base_ref, base_sha, machine, stamp, tsv = sys.argv[1:10]
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
KEY = re.compile(r"\b(ok|passed|failed|FAIL|PASS)\b|errors=|features=|\b[Tt]ests?\b")


def summarize(path):
    try:
        lines = [ANSI.sub("", l).strip() for l in open(path, errors="replace")]
    except OSError:
        return "(로그 없음)"
    lines = [l for l in lines if l]
    if not lines:
        return "(출력 없음)"
    line = next((l for l in reversed(lines) if KEY.search(l)), lines[-1])
    return line if len(line) <= 110 else line[:107] + "..."


def cell(s):
    return s.replace("|", "\\|")


rows, failed, go = [], [], False
for line in open(tsv):
    cmd, rc, secs, log = line.rstrip("\n").split("\t")
    if rc != "0":
        failed.append(cmd)
    go = go or cmd.startswith("cd server && go test")
    rows.append(f"| `{cell(cmd)}` | {rc} | {cell(summarize(log))} | {secs}s |")

verdict = "pass" if not failed else "fail"
out = [
    "## 로컬 검사 (fork-pr-check)",
    "",
    f"- PR: #{pr} ({url}), 브랜치 `{branch}`",
    f"- head: `{sha}`",
    f"- base: `{base_ref}` @ `{base_sha}`",
    f"- 기기: {machine}",
    f"- 시각(UTC): {stamp}",
    "",
    "| 명령 | 종료 코드 | 결과 | 시간 |",
    "|---|---|---|---|",
    *rows,
    "",
]
if failed:
    out.append(f"판정: 실패 {len(failed)}건. " + ", ".join(f"`{cell(c)}`" for c in failed))
else:
    out.append("판정: 통과 (실패 0)")
out += ["", "전체 시험은 출시 CI에서 돈다(포크 규칙: 전체 vitest run 금지)"]
if go:
    out.append("Go 시험은 DATABASE_URL 없이 돌려서 DB가 필요한 시험은 skip된다(이 Mac에 DB를 띄우지 않음).")
out += ["", f"<!-- fork-pr-check pr={pr} head={sha} verdict={verdict} -->"]
print("\n".join(out))
PY

if [ "$CMD" = gate ]; then
  view="$("$GH" pr view "$PR" -R "$REPO" --json number,url,headRefOid,headRefName,baseRefName 2>&1)" \
    || { echo "gate=error reason=gh-pr-view"; echo "$view" >&2; exit 2; }
  fields="$(printf '%s' "$view" | python3 -c "$PRVIEW_PY" 2>&1)" \
    || { echo "gate=error reason=pr-json"; echo "$fields" >&2; exit 2; }
  IFS=$'\t' read -r cur _ <<<"$fields"
  comments="$("$GH" api "repos/$REPO/issues/$PR/comments" --paginate 2>&1)" \
    || { echo "gate=error reason=gh-api"; echo "$comments" >&2; exit 2; }
  printf '%s' "$comments" | python3 -c "$GATE_PY" "$PR" "$cur"
  exit $?
fi

TOP="$(g rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git checkout"
cd "$TOP" || exit 2

view="$("$GH" pr view "$PR" -R "$REPO" --json number,url,headRefOid,headRefName,baseRefName 2>&1)" \
  || die "gh pr view $PR failed: $view"
fields="$(printf '%s' "$view" | python3 -c "$PRVIEW_PY" 2>&1)" || die "unreadable gh pr view output: $fields"
IFS=$'\t' read -r OID BRANCH BASEREF PRURL <<<"$fields"

g fetch -q --no-tags "$REPO_URL" "+refs/pull/$PR/head:refs/fork-pr-check/$PR" 2>&1 \
  || die "could not fetch refs/pull/$PR/head from $REPO_URL"
GOT="$(g rev-parse -q --verify "refs/fork-pr-check/$PR^{commit}")" || die "fetched PR head is not a commit"
[ "$GOT" = "$OID" ] || die "head moved: gh reports $OID, fetched $GOT. Run again."
g fetch -q --no-tags "$REPO_URL" "+refs/heads/$BASEREF:refs/fork-pr-check/base-$PR" 2>&1 \
  || die "could not fetch base branch $BASEREF from $REPO_URL"
BASESHA="$(g rev-parse -q --verify "${BASE_REV:-refs/fork-pr-check/base-$PR}^{commit}")" || die "base is not a commit"
MB="$(g merge-base "$BASESHA" "$OID")" || die "no merge base between $BASEREF and $OID"

PLAN="$(g diff --name-status -z --no-renames "$MB" "$OID" | python3 -c "$PLAN_PY" "$OID" "$MB")" \
  || die "could not plan checks"
if [ "$CMD" = plan ]; then
  printf '%s\n' "$PLAN"
  exit 0
fi

[ -n "$OUT" ] || OUT="$TOP/out/fork-pr-check/$PR-${OID:0:7}"
mkdir -p "$OUT" || die "cannot create $OUT"
: > "$OUT/results.tsv"

g fetch -q --no-tags "$UPSTREAM_URL" '+refs/tags/v*:refs/upstream-tags/v*' 2>&1 \
  || die "could not fetch upstream tags from $UPSTREAM_URL"

TMPW="$(mktemp -d "${TMPDIR:-/tmp}/fork-pr-check.XXXXXX")" || die "mktemp failed"
cleanup() {
  g -C "$TOP" worktree remove --force "$TMPW/wt" >/dev/null 2>&1
  g -C "$TOP" worktree prune >/dev/null 2>&1
  /bin/rm -rf "$TMPW"
}
trap cleanup EXIT
g worktree add -q --detach "$TMPW/wt" "$OID" || die "could not create worktree for $OID"

i=0
while IFS= read -r cmd; do
  i=$((i + 1))
  log="$OUT/$(printf '%02d' "$i").log"
  echo "fork-pr-check: [$i] $cmd" >&2
  start="$(date +%s)"
  (cd "$TMPW/wt" && env -u DATABASE_URL -u DIRECT_URL -u TEST_DATABASE_URL CI=1 bash -c "$cmd") >"$log" 2>&1 </dev/null
  rc=$?
  printf '%s\t%s\t%s\t%s\n' "$cmd" "$rc" "$(($(date +%s) - start))" "$log" >> "$OUT/results.tsv"
done <<<"$PLAN"

if [ "$(uname -s)" = Darwin ]; then
  os="$(sw_vers -productName) $(sw_vers -productVersion)"
else
  os="$(uname -sr)"
fi
MACHINE="$(hostname -s), $(uname -m), $os"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 -c "$BODY_PY" "$PR" "$OID" "$BRANCH" "$PRURL" "$BASEREF" "$BASESHA" "$MACHINE" "$STAMP" "$OUT/results.tsv" > "$OUT/comment.md" \
  || die "could not build the comment body"
cat "$OUT/comment.md"

if [ "$POST" = 1 ]; then
  url="$("$GH" pr comment "$PR" -R "$REPO" --body-file "$OUT/comment.md" 2>&1)" || die "gh pr comment failed: $url"
  echo "$url"
fi

if grep -q '^<!-- fork-pr-check .* verdict=pass -->$' "$OUT/comment.md"; then exit 0; fi
exit 1

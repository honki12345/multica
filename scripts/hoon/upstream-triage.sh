#!/usr/bin/env bash
# Upstream change triage for the honki12345/multica fork (FORK.md "Upstream triage").
#
#   scripts/hoon/upstream-triage.sh <from-tag> <to-ref> [--fork-ref <ref>] [--registry-ref <ref>]
#       [--registry <path>] [--upstream-repo <owner/name>] [--json <file>]
#
# Sorts every non-merge commit in <from-tag>..<to-ref> against the fork feature
# registry (<registry> at <registry-ref>, default fork/features.yml at HEAD):
#   A  touches a file in an active feature's `files`: conflict or behaviour risk
#   B  touches a `watch` path of an active or planned feature: silent breakage,
#      input for the screen comparison
#   C  matches an active or planned feature's `upstream_equivalent`: drop or
#      shrink candidate
#   D  migration, new env key, .env.example / compose / Dockerfile / selfhost
#      script change: backup and config check before deploy
#   E  feat commit about chat, inbox, daemon, hermes, cli or autopilot: absorb
#      candidate
#   F  none of the above
# A commit can carry several labels. C and E are candidates only; the report
# ends with the instruction for the absorb run to confirm them from the PR
# bodies. No LLM, deterministic output, always exits 0.
#
# --fork-ref (default HEAD) is what <to-ref> would be merged into; the report
# marks A commits that touch a file `git merge-tree` reports as conflicting.
#
# Output: a markdown report, then one machine key per line after the
# `--- triage keys` marker: triage_status=ok|error, triage_from, triage_to,
# triage_commits, triage_merge=already-merged|clean|conflict|unknown,
# triage_conflict_files, triage_a .. triage_f, triage_{a,b,c}_features,
# triage_migrations, triage_migration_range, triage_new_env, triage_new_cli,
# triage_removed_cli, triage_cli_help=ok|unavailable|skipped,
# triage_release_notes=ok|none|lookup-failed|skipped, triage_pr_lookup=ok|partial|lookup-failed|skipped.
# --json writes the same classification as JSON (B features and paths are the
# fork-verify screen-test input).
#
# Test overrides:
#   TRIAGE_RELEASE_NOTES_OVERRIDE=<file>  release notes body instead of `gh release view`
#                                         (an empty file means "no release")
#   TRIAGE_PRS_OVERRIDE=<file>            JSON {"<n>": {"title": "...", "labels": ["..."]}} instead of gh
#   TRIAGE_CLI_OVERRIDE=off|<file>        skip the CLI build, or JSON {"from": [...], "to": [...]}
#                                         command paths instead of building both CLIs and walking --help
set -uo pipefail

usage="usage: $0 <from-tag> <to-ref> [--fork-ref <ref>] [--registry-ref <ref>] [--registry <path>] [--upstream-repo <owner/name>] [--json <file>]"
FROM="${1:-}"; TO="${2:-}"
if [ -z "$FROM" ] || [ -z "$TO" ] || [ "${FROM#-}" != "$FROM" ] || [ "${TO#-}" != "$TO" ]; then
  echo "$usage" >&2; exit 2
fi
shift 2
FORK_REF=HEAD
REGISTRY_REF=HEAD
REGISTRY=fork/features.yml
UPSTREAM_REPO=multica-ai/multica
JSON_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fork-ref) FORK_REF="$2"; shift 2 ;;
    --registry-ref) REGISTRY_REF="$2"; shift 2 ;;
    --registry) REGISTRY="$2"; shift 2 ;;
    --upstream-repo) UPSTREAM_REPO="$2"; shift 2 ;;
    --json) JSON_OUT="$2"; shift 2 ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
done

error_out() {
  printf '# 상류 변경 판별 %s → %s\n\n판별 실패: %s\n\n--- triage keys\ntriage_status=error\ntriage_error=%s\n' "$FROM" "$TO" "$1" "$1"
  exit 0
}

if python3 -c 'import yaml' 2>/dev/null; then
  PY=(python3)
elif command -v uv >/dev/null 2>&1; then
  PY=(uv run -q --no-project --with pyyaml python3)
else
  error_out "PyYAML not available: install python3-yaml or uv"
fi

export TR_FROM="$FROM" TR_TO="$TO" TR_FORK_REF="$FORK_REF" TR_REGISTRY_REF="$REGISTRY_REF" \
  TR_REGISTRY="$REGISTRY" TR_UPSTREAM_REPO="$UPSTREAM_REPO" TR_JSON_OUT="$JSON_OUT"
# Buffer the report so a crash never leaves a half report plus an error block.
report="$(mktemp "${TMPDIR:-/tmp}/upstream-triage.XXXXXX")" || error_out "mktemp failed"
trap '/bin/rm -f "$report"' EXIT
if ! "${PY[@]}" - > "$report" <<'PY'

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

import yaml

FROM = os.environ["TR_FROM"]
TO = os.environ["TR_TO"]
FORK_REF = os.environ["TR_FORK_REF"]
REGISTRY_REF = os.environ["TR_REGISTRY_REF"]
REGISTRY = os.environ["TR_REGISTRY"]
REPO = os.environ["TR_UPSTREAM_REPO"]
JSON_OUT = os.environ["TR_JSON_OUT"]
NOTES_OVERRIDE = os.environ.get("TRIAGE_RELEASE_NOTES_OVERRIDE")
PRS_OVERRIDE = os.environ.get("TRIAGE_PRS_OVERRIDE")

INTEREST = re.compile(r"\b(chat|inbox|daemon|hermes|cli|autopilots?)\b", re.I)
FEAT = re.compile(r"(^|[ :])feat(\(|!|:)")
PR_RE = re.compile(r"\(#(\d+)\)")
D_PATHS = ["server/migrations/**", ".env.example", "docker-compose*.yml", "Dockerfile*", "scripts/selfhost*"]
MIGRATION_RE = re.compile(r"^server/migrations/(\d+)_(.+)\.up\.sql$")
ENV_RES = {
    "env.example": (re.compile(r"^\s*#?\s*([A-Z][A-Z0-9_]{2,})="), lambda p: p.endswith(".env.example")),
    "compose": (re.compile(r"\$\{([A-Z][A-Z0-9_]{2,})"), lambda p: p.split("/")[-1].startswith("docker-compose")),
    "go": (re.compile(r"os\.(?:Getenv|LookupEnv)\(\"([A-Z][A-Z0-9_]{2,})\"\)"), lambda p: p.endswith(".go") and not p.endswith("_test.go")),
}
CLI_USE = re.compile(r"\bUse:\s*\"([^\"]+)\"")
CLI_OVERRIDE = os.environ.get("TRIAGE_CLI_OVERRIDE")
HELP_ENTRY = re.compile(r"^  ([a-z0-9][a-z0-9-]*):\s")
LIST_MAX = 3


GIT_PIN = ["-c", "core.quotePath=false", "-c", "diff.noprefix=false", "-c", "diff.mnemonicPrefix=false",
           "-c", "log.showSignature=false", "-c", "diff.external=", "-c", "color.ui=false",
           "-c", "color.diff=false", "-c", "color.grep=false", "-c", "grep.lineNumber=false",
           "-c", "grep.column=false", "-c", "grep.fullName=false"]


def git(*args, check=True):
    res = subprocess.run(["git", *GIT_PIN, *args], capture_output=True)
    if check and res.returncode != 0:
        fail("git %s failed: %s" % (" ".join(args[:3]), res.stderr.decode(errors="replace").strip()))
    return res


def run_tool(*cmd):
    """Run an external tool; None when it is not installed."""
    try:
        return subprocess.run(list(cmd), capture_output=True)
    except OSError:
        return None


def text(res):
    return res.stdout.decode("utf-8", errors="replace")


C_ESCAPES = {"a": 7, "b": 8, "t": 9, "n": 10, "v": 11, "f": 12, "r": 13, '"': 34, "\\": 92}


def unquote_path(s):
    """Undo git's C-style quoting of a diff header path ("a/x\\"y.go")."""
    if not (len(s) >= 2 and s[0] == s[-1] == '"'):
        return s
    raw, out, i = s[1:-1].encode("utf-8"), bytearray(), 0
    while i < len(raw):
        if raw[i] == 92 and i + 1 < len(raw):
            nxt = chr(raw[i + 1])
            if nxt in "01234567" and i + 3 < len(raw):
                out.append(int(raw[i + 1:i + 4], 8))
                i += 4
                continue
            out.append(C_ESCAPES.get(nxt, raw[i + 1]))
            i += 2
        else:
            out.append(raw[i])
            i += 1
    return out.decode("utf-8", errors="replace")


def fail(msg):
    print("# 상류 변경 판별 %s → %s\n\n판별 실패: %s\n\n--- triage keys\ntriage_status=error\ntriage_error=%s" % (FROM, TO, msg, msg))
    sys.exit(0)


def glob_re(pattern):
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out, i = out + "(?:.*/)?", i + 3
        elif pattern.startswith("**", i):
            out, i = out + ".*", i + 2
        elif pattern[i] == "*":
            out, i = out + "[^/]*", i + 1
        elif pattern[i] == "?":
            out, i = out + "[^/]", i + 1
        else:
            out, i = out + re.escape(pattern[i]), i + 1
    return re.compile("^" + out + "$")


def matches(pattern, path):
    return glob_re(pattern).match(path) is not None


for ref in (FROM, TO):
    if git("rev-parse", "-q", "--verify", ref + "^{commit}", check=False).returncode != 0:
        fail("ref %s not found" % ref)

# Registry
raw = git("show", "%s:%s" % (REGISTRY_REF, REGISTRY), check=False)
if raw.returncode != 0:
    fail("registry %s not found at %s" % (REGISTRY, REGISTRY_REF))
try:
    doc = yaml.safe_load(text(raw))
    features = [f for f in doc["features"] if f.get("status") in ("active", "planned")]
except (yaml.YAMLError, KeyError, TypeError, AttributeError) as exc:
    fail("registry %s is unreadable: %s" % (REGISTRY, str(exc).replace("\n", " ")))
active = [f for f in features if f["status"] == "active"]

# Commits and their files. -z keeps paths with spaces, tabs or quotes intact.
commits = []
by_sha = {}
log = git("log", "--no-merges", "--reverse", "-z", "--format=%x01%H%x02%s", "--name-status", "--no-renames",
          "%s..%s" % (FROM, TO)).stdout.decode("utf-8", errors="replace")
for chunk in log.split("\x01")[1:]:
    head, _, rest = chunk.partition("\x00")
    sha, subject = head.split("\x02", 1)
    m = PR_RE.findall(subject)
    c = {"sha": sha, "short": sha[:9], "subject": subject, "pr": int(m[-1]) if m else None,
         "files": {}, "added": {}, "removed": {}, "labels": {}}
    fields = rest.lstrip("\n").split("\x00")
    for status, path in zip(fields[0::2], fields[1::2]):
        if status:
            c["files"][path] = status[0]
    commits.append(c)
    by_sha[sha] = c

# Added and removed lines per file. The header path is matched against the
# commit's -z file list, so quoting and trailing tabs in the header never decide it.
cur_commit, cur_file, in_header = None, None, False
for line in text(git("log", "--no-merges", "--format=%x01%H", "-p", "--unified=0", "--no-renames",
                     "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/",
                     "%s..%s" % (FROM, TO))).split("\n"):
    if line.startswith("\x01"):
        cur_commit, cur_file, in_header = by_sha.get(line[1:]), None, False
    elif line.startswith("diff --git "):
        cur_file, in_header = None, True
    elif in_header:
        if cur_commit and line.startswith(("--- ", "+++ ")) and line[4:] != "/dev/null":
            cand = unquote_path(line[4:].rstrip("\t"))[2:]
            if cand in cur_commit["files"]:
                cur_file = cand
        elif line.startswith("@@"):
            in_header = False
    elif cur_commit and cur_file and line[:1] in ("+", "-"):
        side = "added" if line[0] == "+" else "removed"
        cur_commit[side].setdefault(cur_file, []).append(line[1:])


def present_at_from(words, word_match):
    """Which of words already occur anywhere in the FROM tree."""
    if not words:
        return set()
    args = ["grep", "-h", "-o", "-F"] + (["-w"] if word_match else [])
    for w in sorted(words):
        args += ["-e", w]
    return set(text(git(*args, FROM, check=False)).split("\n")) & set(words)


# Release notes and PR metadata (network; failures are reported, not fatal)
notes_state, notes_url, notes_published, notes_lines = "none", "", "", {}
if NOTES_OVERRIDE is not None:
    body = open(NOTES_OVERRIDE, encoding="utf-8").read() if os.path.exists(NOTES_OVERRIDE) else ""
    notes_state = "ok" if body.strip() else "none"
elif git("show-ref", "-q", "--verify", "refs/tags/" + TO, check=False).returncode != 0:
    body, notes_state = "", "skipped"
else:
    res = run_tool("gh", "release", "view", TO, "-R", REPO, "--json", "url,publishedAt,body")
    body = ""
    try:
        info = json.loads(res.stdout) if res is not None and res.returncode == 0 else None
    except ValueError:
        info = None
    if isinstance(info, dict):
        body, notes_url, notes_published, notes_state = info.get("body") or "", info.get("url") or "", info.get("publishedAt") or "", "ok"
    elif res is not None and b"release not found" in res.stderr:
        notes_state = "none"
    else:
        notes_state = "lookup-failed"
for line in body.splitlines():
    m = re.match(r"^\*\s+([0-9a-f]{7,40})\s+(.*)$", line.strip())
    if m:
        notes_lines[m.group(1)] = m.group(2)


def notes_line(c):
    for k, v in notes_lines.items():
        if c["sha"].startswith(k):
            return v
    return None


pr_numbers = sorted({c["pr"] for c in commits if c["pr"]})
prs, pr_state = {}, "skipped"
if PRS_OVERRIDE is not None:
    prs = {int(k): v for k, v in json.load(open(PRS_OVERRIDE, encoding="utf-8")).items()}
    pr_state = "ok"
elif pr_numbers:
    owner, _, name = REPO.partition("/")
    pr_state = "ok"
    for i in range(0, len(pr_numbers), 50):
        chunk = pr_numbers[i:i + 50]
        q = "query{repository(owner:%s,name:%s){%s}}" % (json.dumps(owner), json.dumps(name), " ".join(
            "p%d:pullRequest(number:%d){title labels(first:20){nodes{name}}}" % (n, n) for n in chunk))
        res = run_tool("gh", "api", "graphql", "-f", "query=" + q)
        try:
            data = json.loads(res.stdout)["data"]["repository"]
        except (AttributeError, ValueError, KeyError, TypeError):
            data = None
        if not isinstance(data, dict):
            pr_state = "lookup-failed"
            continue
        for n in chunk:
            node = data.get("p%d" % n)
            if node:
                prs[n] = {"title": node["title"], "labels": sorted(l["name"] for l in node["labels"]["nodes"])}
            elif pr_state == "ok":
                pr_state = "partial"
    if pr_state == "lookup-failed" and prs:
        pr_state = "partial"

# Symbols and env keys that upstream already had at FROM do not count as new.
symbols = {s for f in features for s in (f.get("upstream_equivalent") or {}).get("symbols") or []}
old_symbols = present_at_from(symbols, False)

env_found = {}
for c in commits:
    for path, lines in c["added"].items():
        for kind, (rx, applies) in ENV_RES.items():
            if applies(path):
                for l in lines:
                    for key in rx.findall(l):
                        env_found.setdefault(key, []).append((c, path))
old_env = present_at_from(set(env_found), True)

# Merge risk
merge_state, conflict_files = "unknown", []
if git("rev-parse", "-q", "--verify", FORK_REF + "^{commit}", check=False).returncode == 0:
    if git("merge-base", "--is-ancestor", TO, FORK_REF, check=False).returncode == 0:
        merge_state = "already-merged"
    else:
        res = git("merge-tree", "--write-tree", "--name-only", "--no-messages", FORK_REF, TO, check=False)
        if res.returncode == 0:
            merge_state = "clean"
        elif res.returncode == 1:
            merge_state = "conflict"
            conflict_files = sorted({l for l in text(res).split("\n")[1:] if l})

# Classification
for c in commits:
    files = sorted(c["files"])
    pr = prs.get(c["pr"]) or {}
    haystack = " ".join([c["subject"], pr.get("title", ""), " ".join(pr.get("labels", [])), notes_line(c) or ""]).lower()
    added_all = "\n".join(l for ls in c["added"].values() for l in ls)

    a = []
    for f in active:
        hit = [p for p in files if p in f["files"]]
        if hit:
            a.append({"feature": f["id"], "files": hit, "conflict": [p for p in hit if p in conflict_files]})
    if a:
        c["labels"]["A"] = a

    b = []
    for f in features:
        # A planned feature's own files are where its work will land, so an
        # upstream change there is surrounding change, not a conflict.
        own = f["files"] if f["status"] == "active" else []
        hit = [p for p in files if p not in own and (
            p in f["files"] or any(matches(w["path"], p) for w in f.get("watch") or []))]
        if hit:
            b.append({"feature": f["id"], "status": f["status"], "files": hit})
    if b:
        c["labels"]["B"] = b

    cands = []
    for f in features:
        ue = f.get("upstream_equivalent") or {}
        ev = []
        if c["pr"] and c["pr"] in (ue.get("prs") or []):
            ev.append("PR #%d이 레지스트리에 등록됨" % c["pr"])
        for s in ue.get("symbols") or []:
            if s not in old_symbols and s in added_all:
                ev.append("새 심볼 `%s`" % s)
        for k in ue.get("keywords") or []:
            if re.search(r"(?<![a-z0-9])" + re.escape(k.lower()) + r"(?:s|es)?(?![a-z0-9])", haystack):
                ev.append("키워드 `%s`" % k)
        if ev:
            cands.append({"feature": f["id"], "status": f["status"], "cards": f.get("cards") or [],
                          "evidence": ev, "drop_when": f.get("drop_when", "")})
    if cands:
        c["labels"]["C"] = cands

    d = {}
    dpaths = [p for p in files if any(matches(g, p) for g in D_PATHS)]
    if dpaths:
        d["files"] = dpaths
    migs = []
    for p in files:
        m = MIGRATION_RE.match(p)
        if m:
            migs.append({"number": int(m.group(1)), "name": m.group(2), "path": p, "status": c["files"][p]})
    if migs:
        d["migrations"] = migs
    keys = sorted({k for k, hits in env_found.items() if k not in old_env for hc, _ in hits if hc is c})
    if keys:
        d["env"] = keys
    if d:
        c["labels"]["D"] = d

    if FEAT.search(c["subject"]) and INTEREST.search(c["subject"]):
        c["labels"]["E"] = sorted({m.lower() for m in INTEREST.findall(c["subject"])})

    for path, lines in c["added"].items():
        if path.startswith("server/cmd/multica/") and path.endswith(".go") and not path.endswith("_test.go"):
            removed = set(CLI_USE.findall("\n".join(c["removed"].get(path, []))))
            new = [u for u in CLI_USE.findall("\n".join(lines)) if u not in removed]
            if new:
                c.setdefault("cli", []).append({"file": path, "uses": new})

    if not c["labels"]:
        c["labels"]["F"] = True


def cli_tree(ref, tmp):
    """Every command path of the CLI built from <ref>, read by walking --help."""
    src = os.path.join(tmp, ref.replace("/", "_"))
    os.makedirs(src)
    archive = subprocess.run(["git", "archive", "--format=tar", ref, "server"], capture_output=True)
    if archive.returncode != 0 or subprocess.run(["tar", "-x", "-C", src], input=archive.stdout).returncode != 0:
        return None
    binary = os.path.join(src, "multica")
    if subprocess.run(["go", "build", "-o", binary, "./cmd/multica"], cwd=os.path.join(src, "server"),
                      capture_output=True).returncode != 0:
        return None
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": src}
    paths, queue = set(), [[]]
    while queue:
        path = queue.pop()
        res = subprocess.run([binary, *path, "--help"], capture_output=True, env=env, timeout=30)
        in_cmds = False
        for line in res.stdout.decode("utf-8", errors="replace").splitlines():
            if line and not line[0].isspace():
                in_cmds = line.rstrip().endswith("COMMANDS")
                continue
            m = HELP_ENTRY.match(line)
            if in_cmds and m and m.group(1) != "help" and len(path) < 6:
                child = path + [m.group(1)]
                paths.add(" ".join(child))
                queue.append(child)
    return paths


cli_state, cli_new, cli_removed = "skipped", [], []
if CLI_OVERRIDE == "off":
    pass
elif CLI_OVERRIDE:
    trees = json.load(open(CLI_OVERRIDE, encoding="utf-8"))
    old_tree, new_tree = set(trees["from"]), set(trees["to"])
    cli_state = "ok"
elif shutil.which("go"):
    tmp = tempfile.mkdtemp(prefix="upstream-triage-")
    try:
        old_tree, new_tree = cli_tree(FROM, tmp), cli_tree(TO, tmp)
    except (OSError, subprocess.TimeoutExpired):
        old_tree = new_tree = None
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    cli_state = "ok" if old_tree and new_tree else "unavailable"
else:
    cli_state = "unavailable"
if cli_state == "ok":
    cli_new, cli_removed = sorted(new_tree - old_tree), sorted(old_tree - new_tree)

# Report
def esc(s):
    return s.replace("|", "\\|")


def pr_link(c):
    return "[#%d](https://github.com/%s/pull/%d)" % (c["pr"], REPO, c["pr"]) if c["pr"] else "-"


def short_list(items, n=LIST_MAX):
    items = ["`%s`" % i for i in items]
    return ", ".join(items[:n]) + (" 외 %d" % (len(items) - n) if len(items) > n else "")


def with_label(label):
    return [c for c in commits if label in c["labels"]]


def feature_ids(label):
    return sorted({x["feature"] for c in with_label(label) for x in c["labels"][label]})


out = []
w = out.append
w("# 상류 변경 판별 `%s` → `%s`" % (FROM, TO))
w("")
w("- 범위: merge 아닌 커밋 %d개. 레지스트리 `%s` @ `%s` (active %d, planned %d)." % (
    len(commits), REGISTRY, REGISTRY_REF, len(active), len(features) - len(active)))
if notes_state == "ok":
    w("- 릴리스 노트: %s (%s). 노트의 커밋 %d개." % (notes_url or "override", notes_published or "-", len(notes_lines)))
else:
    w("- 릴리스 노트: %s." % {"none": "없음", "skipped": "태그가 아니라 조회 안 함", "lookup-failed": "조회 실패(gh)"}[notes_state])
missing = [c for c in commits if notes_lines and notes_line(c) is None]
if missing:
    w("- 릴리스 노트에 없는 커밋 %d개: %s." % (len(missing), short_list([c["short"] for c in missing], 8)))
w("- PR 정보: %s (%d/%d)." % (pr_state, len(prs), len(pr_numbers)))
merge_text = {"already-merged": "이미 merge됨", "clean": "충돌 없음", "unknown": "확인 못 함"}.get(merge_state)
w("- `%s`에 merge: %s." % (FORK_REF, merge_text or "충돌 %d파일 (%s)" % (len(conflict_files), short_list(conflict_files, 10))))
w("")
w("| 분류 | 뜻 | 커밋 수 | 개조 |")
w("|---|---|---|---|")
meaning = {"A": "개조 파일 직접 수정", "B": "개조 주변 수정 (화면 비교 대상)", "C": "상류가 같은 기능 (후보)",
           "D": "마이그레이션·설정·env", "E": "흡수 후보 새 기능 (후보)", "F": "무관"}
for k in "ABCDEF":
    ids = ", ".join("`%s`" % i for i in feature_ids(k)) if k in "ABC" else ""
    w("| %s | %s | %d | %s |" % (k, meaning[k], len(with_label(k)), ids))
w("")
w("한 커밋이 여러 분류에 들 수 있습니다.")

w("")
w("## A. 우리 개조 파일 직접 수정")
w("")
if with_label("A"):
    w("| 커밋 | PR | 제목 | 개조 | 근거 파일 |")
    w("|---|---|---|---|---|")
    for c in with_label("A"):
        for x in c["labels"]["A"]:
            files = ["%s%s" % (p, " ⚔️충돌" if p in x["conflict"] else "") for p in x["files"]]
            w("| `%s` | %s | %s | `%s` | %s |" % (c["short"], pr_link(c), esc(c["subject"]), x["feature"], short_list(files, 4)))
else:
    w("없음.")

w("")
w("## B. 개조 주변 수정")
w("")
if with_label("B"):
    w("| 개조 | 상태 | 바뀐 watch 파일 | 커밋 |")
    w("|---|---|---|---|")
    for fid in feature_ids("B"):
        rows = [(c, x) for c in with_label("B") for x in c["labels"]["B"] if x["feature"] == fid]
        paths = sorted({p for _, x in rows for p in x["files"]})
        w("| `%s` | %s | %d개: %s | %s |" % (fid, rows[0][1]["status"], len(paths), short_list(paths, 5),
                                          short_list([c["short"] for c, _ in rows], 6)))
else:
    w("없음.")

w("")
w("## C. 상류가 같은 기능을 넣음 (후보)")
w("")
if with_label("C"):
    w("| 커밋 | PR | 제목 | 개조 (카드) | 근거 |")
    w("|---|---|---|---|---|")
    for c in with_label("C"):
        for x in c["labels"]["C"]:
            cards = " (%s)" % ", ".join(x["cards"]) if x["cards"] else ""
            w("| `%s` | %s | %s | `%s`%s | %s |" % (c["short"], pr_link(c), esc(c["subject"]), x["feature"], cards, "; ".join(x["evidence"])))
    w("")
    w("버리는 조건(`drop_when`):")
    for fid in feature_ids("C"):
        f = next(f for f in features if f["id"] == fid)
        w("- `%s`: %s" % (fid, f.get("drop_when", "").strip()))
else:
    w("없음.")

w("")
w("## D. 마이그레이션·설정·env")
w("")
migs = sorted((m for c in with_label("D") for m in c["labels"]["D"].get("migrations", [])), key=lambda m: m["number"])
new_migs = []
for line in text(git("diff", "--name-status", "--no-renames", FROM, TO, "--", "server/migrations")).split("\n"):
    m = MIGRATION_RE.match(line.split("\t", 1)[-1]) if line.startswith("A\t") else None
    if m:
        new_migs.append({"number": int(m.group(1)), "name": m.group(2)})
new_migs.sort(key=lambda m: m["number"])
if migs:
    rng = "%d~%d" % (new_migs[0]["number"], new_migs[-1]["number"]) if new_migs else "-"
    w("**마이그레이션:** `%s`에 없던 up 파일 %d개 (%s). 배포 전 `pg_dump` 백업이 필요합니다." % (FROM, len(new_migs), rng))
    w("")
    w("| 커밋 | PR | 번호 | 이름 |")
    w("|---|---|---|---|")
    for c in with_label("D"):
        for m in c["labels"]["D"].get("migrations", []):
            note = "" if m["status"] == "A" else " ⚠️ 기존 파일 %s" % ("수정" if m["status"] == "M" else "삭제")
            w("| `%s` | %s | %d | `%s`%s |" % (c["short"], pr_link(c), m["number"], m["name"], note))
else:
    w("**마이그레이션:** 없음.")
w("")
new_env = sorted({k for c in with_label("D") for k in c["labels"]["D"].get("env", [])})
if new_env:
    w("**새 env 키:** `%s`에 없던 키입니다. self-host `.env`·compose에 넣을지 확인합니다." % FROM)
    w("")
    w("| 키 | 처음 나온 곳 |")
    w("|---|---|")
    for k in new_env:
        where = sorted({"`%s` %s" % (c["short"], p) for c, p in env_found[k] if "env" in c["labels"].get("D", {})})
        w("| `%s` | %s |" % (k, ", ".join(where[:LIST_MAX]) + (" 외 %d" % (len(where) - LIST_MAX) if len(where) > LIST_MAX else "")))
else:
    w("**새 env 키:** 없음.")
w("")
cfg = [(c, [p for p in c["labels"]["D"].get("files", []) if not p.startswith("server/migrations/")]) for c in with_label("D")]
cfg = [(c, ps) for c, ps in cfg if ps]
if cfg:
    w("**설정 파일 변경:**")
    w("")
    for c, ps in cfg:
        w("- `%s` %s %s: %s" % (c["short"], pr_link(c), esc(c["subject"]), short_list(ps, 5)))
else:
    w("**설정 파일 변경:** 없음.")

w("")
w("## E. 흡수하면 좋은 새 기능 (후보)")
w("")
if with_label("E"):
    w("| 커밋 | PR | 제목 | 영역 | C와 겹침 |")
    w("|---|---|---|---|---|")
    for c in with_label("E"):
        overlap = ", ".join("`%s`" % x["feature"] for x in c["labels"].get("C", [])) or "-"
        w("| `%s` | %s | %s | %s | %s |" % (c["short"], pr_link(c), esc(c["subject"]), ", ".join(c["labels"]["E"]), overlap))
else:
    w("없음.")

w("")
w("## 새 CLI 명령")
w("")
cli = [(c, x) for c in commits for x in c.get("cli", [])]
if cli_state == "ok":
    w("`%s`와 `%s`로 CLI를 각각 빌드해 `--help` 트리를 비교했습니다." % (FROM, TO))
    w("")
    w("- 새 명령 %d개: %s" % (len(cli_new), ", ".join("`multica %s`" % p for p in cli_new) or "없음"))
    w("- 없어진 명령 %d개: %s" % (len(cli_removed), ", ".join("`multica %s`" % p for p in cli_removed) or "없음"))
else:
    w("`--help` 트리 비교: %s(%s). 아래 소스 비교만 봅니다." % (
        {"skipped": "건너뜀", "unavailable": "못 함"}[cli_state],
        "TRIAGE_CLI_OVERRIDE=off" if cli_state == "skipped" else "go 없음 또는 빌드 실패"))
if cli:
    w("")
    w("명령을 넣은 커밋(`server/cmd/multica`의 새 cobra `Use:`):")
    w("")
    for c, x in cli:
        w("- `%s` %s `%s`: %s" % (c["short"], pr_link(c), x["file"], ", ".join("`%s`" % u for u in x["uses"])))
elif cli_state != "ok":
    w("")
    w("없음.")

w("")
w("## F. 무관")
w("")
f_commits = with_label("F")
w("%d개." % len(f_commits))
if f_commits:
    w("")
    w("<details><summary>목록</summary>")
    w("")
    for c in f_commits:
        w("- `%s` %s %s" % (c["short"], pr_link(c), esc(c["subject"])))
    w("")
    w("</details>")

w("")
w("## 흡수 실행 에이전트가 할 일")
w("")
w("이 보고는 파일 경로·키워드로만 가른 결과입니다. 흡수 카드를 실행하는 에이전트는 아래를 확정해 카드 댓글에 적습니다.")
w("")
w("1. **C 후보:** PR 본문(`gh pr view <n> -R %s`)을 읽고 개조의 `drop_when`이 충족됐는지 판정합니다. 결과는 \"버림 / 줄임 / 유지\"와 근거입니다. 버리거나 줄이면 그 흡수 PR에서 `fork/features.yml`도 고칩니다." % REPO)
w("2. **E 후보:** PR 본문을 읽고 우리 작업 카드와 겹치는지, 바로 쓸 수 있는지 적습니다.")
w("3. **A:** ⚔️충돌 파일은 양쪽 변경을 한 줄씩 요약하고 해결 기본안을 적습니다. 충돌이 없는 A 커밋도 개조 동작이 바뀌는지 diff를 봅니다.")
w("4. **B:** 해당 개조의 `scenarios`를 화면·기능 시험(`fork-verify.sh`)으로 돌립니다.")
w("5. **D:** 배포 전 백업, 새 env 키를 self-host 설정에 넣을지, 마이그레이션 전담 리뷰가 필요한지 정합니다.")

json_error = ""
if JSON_OUT:
    data = {
        "from": FROM, "to": TO, "fork_ref": FORK_REF, "merge": merge_state, "conflict_files": conflict_files,
        "commits": [{"sha": c["sha"], "subject": c["subject"], "pr": c["pr"], "labels": c["labels"],
                     "pr_labels": (prs.get(c["pr"]) or {}).get("labels", []), "cli": c.get("cli", [])} for c in commits],
        "migrations": new_migs, "new_env": new_env,
        "cli_help": cli_state, "new_cli": cli_new, "removed_cli": cli_removed,
        "screen_inputs": [{"feature": fid, "paths": sorted({p for c in with_label("B") for x in c["labels"]["B"]
                                                            if x["feature"] == fid for p in x["files"]})}
                          for fid in feature_ids("B")],
    }
    try:
        with open(JSON_OUT, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2, sort_keys=True)
            fh.write("\n")
    except OSError as exc:
        json_error = "%s: %s" % (JSON_OUT, exc.strerror or exc)

w("")
w("--- triage keys")
keys = [
    ("triage_status", "error" if json_error else "ok"), ("triage_from", FROM), ("triage_to", TO), ("triage_commits", len(commits)),
    ("triage_merge", merge_state), ("triage_conflict_files", " ".join(conflict_files)),
]
keys += [("triage_%s" % k.lower(), len(with_label(k))) for k in "ABCDEF"]
keys += [("triage_%s_features" % k.lower(), ",".join(feature_ids(k))) for k in "ABC"]
keys += [
    ("triage_migrations", len(new_migs)),
    ("triage_migration_range", "%d-%d" % (new_migs[0]["number"], new_migs[-1]["number"]) if new_migs else ""),
    ("triage_new_env", ",".join(new_env)),
    ("triage_new_cli", ",".join(p.replace(" ", ".") for p in cli_new)),
    ("triage_removed_cli", ",".join(p.replace(" ", ".") for p in cli_removed)),
    ("triage_cli_help", cli_state),
    ("triage_release_notes", notes_state), ("triage_pr_lookup", pr_state),
]
if json_error:
    keys.insert(1, ("triage_error", "--json write failed: " + json_error))
for k, v in keys:
    w("%s=%s" % (k, v))
print("\n".join(out))
PY
then
  error_out "triage script crashed"
fi
cat "$report"
exit 0

#!/usr/bin/env bash
# Fork feature registry check for the honki12345/multica fork (see FORK.md
# "Fork feature registry").
#
#   scripts/hoon/features-check.sh [--head <ref>] [--tag-prefix <refs/...>] [--base <tag>] [--registry <path>]
#
# Reads the registry (default fork/features.yml) and the tree from <head>, not
# the working copy. The base tag is chosen like license-check.sh: the newest
# upstream vX.Y.Z tag under <tag-prefix> (default refs/upstream-tags/) merged
# into <head>.
#
# Failures (exit 1):
#   a. Registry format: required keys, enums, unique ids, known commits.
#   b. A `files` entry of an active feature is missing at <head> (unless it is
#      an upstream file the feature deletes); a `watch` path or glob of an
#      active or planned feature matches nothing.
#   c. A file that differs from the base tag (changed, added or deleted) is
#      claimed by no active feature's `files` and no `infrastructure` entry.
#   d. A `tests` entry of an active or planned feature names a Go test
#      function or vitest file/case that does not exist.
# `dropped` features are format-checked only.
# Warnings (exit 0):
#   - An upstream file listed in an active feature's `files` is identical to
#     the base tag (stale entry, or upstream took our change).
#   - A planned feature's file already differs from the base tag (flip it to
#     active when the work lands).
set -uo pipefail

HEAD_REF=HEAD
PREFIX=refs/upstream-tags/
BASE=""
REGISTRY=fork/features.yml
while [ $# -gt 0 ]; do
  case "$1" in
    --head) HEAD_REF="$2"; shift 2 ;;
    --tag-prefix) PREFIX="${2%/}/"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --registry) REGISTRY="$2"; shift 2 ;;
    *) echo "usage: $0 [--head <ref>] [--tag-prefix <refs/...>] [--base <tag>] [--registry <path>]" >&2; exit 2 ;;
  esac
done

fatal() { echo "::error::$1"; echo "features-check: base=${BASE:-?} features=? errors=1 warnings=0"; exit 1; }

git rev-parse -q --verify "$HEAD_REF^{commit}" >/dev/null || fatal "head ref $HEAD_REF not found"
if [ -z "$BASE" ]; then
  tags="$(git for-each-ref --sort=-v:refname --format='%(refname)' "$PREFIX" |
    sed "s#^${PREFIX}##" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$')"
  [ -n "$tags" ] || fatal "no upstream release tags under $PREFIX"
  for t in $tags; do
    if git merge-base --is-ancestor "$PREFIX$t" "$HEAD_REF" 2>/dev/null; then BASE="$t"; break; fi
  done
  [ -n "$BASE" ] || fatal "no upstream release tag is merged into $HEAD_REF"
fi
git rev-parse -q --verify "$PREFIX$BASE^{commit}" >/dev/null || fatal "base tag $BASE not found under $PREFIX"

if python3 -c 'import yaml' 2>/dev/null; then
  PY=(python3)
elif command -v uv >/dev/null 2>&1; then
  PY=(uv run -q --no-project --with pyyaml python3)
else
  fatal "PyYAML not available: install python3-yaml or uv"
fi

export FC_HEAD="$HEAD_REF" FC_BASE_REF="$PREFIX$BASE" FC_BASE="$BASE" FC_REGISTRY="$REGISTRY"
exec "${PY[@]}" - <<'PY'
import os
import re
import subprocess
import sys

import yaml

HEAD = os.environ["FC_HEAD"]
BASE_REF = os.environ["FC_BASE_REF"]
BASE = os.environ["FC_BASE"]
REGISTRY = os.environ["FC_REGISTRY"]

KINDS = {"server", "cli", "daemon", "web-ui", "desktop"}
STATUSES = {"active", "planned", "dropped"}
ORIGINS = {"ours", "upstream-cherry-pick"}
ID_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
CARD_RE = re.compile(r"^[A-Z]+-[0-9]+$")

errors = []
warnings = []


def error(msg):
    errors.append(msg)
    print("::error::" + msg)


def warn(msg):
    warnings.append(msg)
    print("::warning::" + msg)


def git(*args, check=True):
    res = subprocess.run(["git", "-c", "core.quotePath=false", *args], capture_output=True)
    if check and res.returncode != 0:
        sys.exit("git %s failed: %s" % (" ".join(args), res.stderr.decode(errors="replace")))
    return res


def finish(count):
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write("## Fork feature registry (base `%s`)\n" % BASE)
            for m in errors:
                fh.write("- ❌ %s\n" % m)
            for m in warnings:
                fh.write("- ⚠️ %s\n" % m)
            if not errors and not warnings:
                fh.write("- ✅ all checks passed\n")
    print("features-check: base=%s features=%s errors=%d warnings=%d" % (BASE, count, len(errors), len(warnings)))
    sys.exit(1 if errors else 0)


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


raw = git("show", "%s:%s" % (HEAD, REGISTRY), check=False)
if raw.returncode != 0:
    error("registry %s not found at %s" % (REGISTRY, HEAD))
    finish("?")
try:
    doc = yaml.safe_load(raw.stdout.decode("utf-8"))
except yaml.YAMLError as exc:
    error("registry is not valid YAML: %s" % str(exc).replace("\n", " "))
    finish("?")

# A " #" inside a plain (unquoted) scalar starts a YAML comment and silently
# cuts the value short (drop_when: ... PR #10119 ... became "... PR"). A cut
# and an intended trailing comment look the same to YAML, so the registry
# allows full-line comments only: ask the parser where each plain scalar ends
# and fail on a "#" after it on the same line.
registry_text = raw.stdout.decode("utf-8")
registry_lines = registry_text.splitlines()
for node_ev in yaml.parse(registry_text):
    if not isinstance(node_ev, yaml.ScalarEvent) or node_ev.style is not None:
        continue
    end = node_ev.end_mark
    rest = registry_lines[end.line][end.column:] if end.line < len(registry_lines) else ""
    if rest.lstrip().startswith("#"):
        error("registry line %d: '#' after an unquoted value (YAML cuts it there); quote the value or move the comment to its own line" % (end.line + 1))

tree = set(git("ls-tree", "-r", "--name-only", HEAD).stdout.decode("utf-8").splitlines())
base_tree = set(git("ls-tree", "-r", "--name-only", BASE_REF).stdout.decode("utf-8").splitlines())
changed = {}
for line in git("diff", "--name-status", "--no-renames", BASE_REF, HEAD).stdout.decode("utf-8").splitlines():
    status, path = line.split("\t", 1)
    changed[path] = status[0]


def blob(ref, path):
    return git("show", "%s:%s" % (ref, path), check=False).stdout.decode("utf-8", errors="replace")


def str_list(value):
    return isinstance(value, list) and all(isinstance(v, str) and v for v in value)


def nonempty_str_list(value):
    return str_list(value) and len(value) > 0


# a. format
if not isinstance(doc, dict) or doc.get("version") != 1:
    error("registry must be a mapping with version: 1")
    finish("?")
features = doc.get("features")
if not isinstance(features, list) or not features:
    error("registry needs a non-empty features list")
    finish("?")
infra = doc.get("infrastructure") or []
infra_paths = []
for item in infra:
    if not isinstance(item, dict) or not isinstance(item.get("path"), str):
        error("infrastructure entries need a path: %r" % (item,))
    else:
        infra_paths.append(item["path"])

seen = set()
valid = []
for n, f in enumerate(features):
    if not isinstance(f, dict):
        error("features[%d] is not a mapping" % n)
        continue
    fid = f.get("id")
    where = "feature %s" % (fid if isinstance(fid, str) else "#%d" % n)
    bad = len(errors)
    if not isinstance(fid, str) or not ID_RE.match(fid):
        error("%s: id must be lowercase-kebab" % where)
    elif fid in seen:
        error("%s: duplicate id" % where)
    seen.add(fid)
    for key in ("summary", "drop_when"):
        if not isinstance(f.get(key), str) or not f.get(key).strip():
            error("%s: %s must be a non-empty string" % (where, key))
    status = f.get("status")
    if status not in STATUSES:
        error("%s: status must be one of %s" % (where, sorted(STATUSES)))
    if f.get("kind") not in KINDS:
        error("%s: kind must be one of %s" % (where, sorted(KINDS)))
    cards = f.get("cards", [])
    if not isinstance(cards, list) or not all(isinstance(c, str) and CARD_RE.match(c) for c in cards):
        error("%s: cards must be a list like [CALA-72]" % where)
    origin = f.get("origin")
    if not isinstance(origin, dict) or origin.get("type") not in ORIGINS:
        error("%s: origin.type must be one of %s" % (where, sorted(ORIGINS)))
    else:
        if origin["type"] == "upstream-cherry-pick" and not isinstance(origin.get("upstream_pr"), int):
            error("%s: an upstream cherry-pick needs origin.upstream_pr" % where)
        commits = origin.get("commits", [])
        if not str_list(commits):
            error("%s: origin.commits must be a list of quoted commit ids" % where)
        else:
            if status == "active" and not commits:
                error("%s: an active feature needs origin.commits" % where)
            for sha in commits:
                if git("cat-file", "-e", "%s^{commit}" % sha, check=False).returncode != 0:
                    error("%s: origin commit %s not found" % (where, sha))
    if not str_list(f.get("files")) or not f.get("files"):
        error("%s: files must be a non-empty list of paths" % where)
    watch = f.get("watch", [])
    if not isinstance(watch, list) or not all(
        isinstance(w, dict) and isinstance(w.get("path"), str) and isinstance(w.get("why"), str) and w["why"].strip()
        for w in watch
    ):
        error("%s: watch entries need path and why" % where)
    ue = f.get("upstream_equivalent")
    if not isinstance(ue, dict) or not any(ue.get(k) for k in ("prs", "symbols", "keywords")):
        error("%s: upstream_equivalent needs prs, symbols or keywords" % where)
    tests = f.get("tests", [])
    if not isinstance(tests, list) or not all(isinstance(t, dict) and ("go" in t) != ("vitest" in t) for t in tests):
        error("%s: each test is {go: <pkg dir>, name: <TestFunc>} or {vitest: <file>[, name: <case>]}" % where)
    elif any("go" in t and not isinstance(t.get("name"), str) for t in tests):
        error("%s: a go test needs a name" % where)
    scenarios = f.get("scenarios", [])
    if not isinstance(scenarios, list) or not all(
        isinstance(s, dict) and isinstance(s.get("name"), str) and nonempty_str_list(s.get("steps")) and nonempty_str_list(s.get("expect"))
        for s in scenarios
    ):
        error("%s: each scenario needs name, steps and expect" % where)
    elif f.get("kind") == "web-ui" and not all(
        isinstance(s.get("path"), str) and isinstance(s.get("widths"), list) and s["widths"] for s in scenarios
    ):
        error("%s: web-ui scenarios need path and widths" % where)
    if status == "active":
        if not tests and not (isinstance(f.get("tests_gap"), str) and f["tests_gap"].strip()):
            error("%s: an active feature needs tests, or tests_gap saying why not" % where)
        if not scenarios:
            error("%s: an active feature needs scenarios" % where)
    if len(errors) == bad:
        valid.append(f)

active = [f for f in valid if f["status"] == "active"]
planned = [f for f in valid if f["status"] == "planned"]

# b. files and watch exist. A deleted upstream file is a legitimate entry: the
# feature owns the deletion. Dropped features are history; their files, watch
# paths and tests may be gone.
for f in active:
    for path in f["files"]:
        if path not in tree and changed.get(path) != "D":
            error("feature %s: file not found at %s: %s" % (f["id"], HEAD, path))
for f in active + planned:
    for w in f.get("watch", []):
        if not any(matches(w["path"], p) for p in tree):
            error("feature %s: watch matches no file: %s" % (f["id"], w["path"]))
for p in infra_paths:
    if not any(matches(p, t) for t in tree | set(changed)):
        error("infrastructure path matches no file: %s" % p)

# c. every fork difference is claimed
claimed = {}
for f in active:
    for path in f["files"]:
        claimed.setdefault(path, []).append(f["id"])
for path, st in sorted(changed.items()):
    if path in claimed or any(matches(p, path) for p in infra_paths):
        continue
    kind = {"A": "added", "D": "deleted"}.get(st, "modified")
    error("%s file is claimed by no feature (add it to a feature's files in %s): %s" % (kind, REGISTRY, path))
for f in active:
    for path in f["files"]:
        if path in base_tree and path not in changed:
            warn("feature %s: %s is identical to upstream %s (stale entry, or upstream took the change?)" % (f["id"], path, BASE))
for f in planned:
    for path in f["files"]:
        if path in changed:
            warn("planned feature %s: %s already differs from %s; set status: active when it lands" % (f["id"], path, BASE))

# d. tests exist
for f in active + planned:
    for t in f.get("tests", []):
        if "go" in t:
            pkg = t["go"].rstrip("/")
            files = [p for p in tree if p.startswith(pkg + "/") and "/" not in p[len(pkg) + 1:] and p.endswith("_test.go")]
            pat = re.compile(r"^func %s\(t \*testing\.T\)" % re.escape(t["name"]), re.M)
            if not any(pat.search(blob(HEAD, p)) for p in files):
                error("feature %s: Go test %s not found in %s" % (f["id"], t["name"], pkg))
        else:
            path = t["vitest"]
            if path not in tree:
                error("feature %s: vitest file not found: %s" % (f["id"], path))
                continue
            name = t.get("name")
            if name:
                body = blob(HEAD, path)
                if not any(("%s(%s%s%s" % (fn, q, name, q)) in body for fn in ("it", "test") for q in "\"'`"):
                    error("feature %s: vitest case %r not found in %s" % (f["id"], name, path))

finish(len(valid) if len(valid) == len(features) else "%d/%d" % (len(valid), len(features)))
PY

#!/usr/bin/env bash
# Absorb gate for the honki12345/multica fork (FORK.md "Absorb gate").
#
# Makes the "stop and ask the user" comment of an upstream absorb card
# structurally complete and identical every time.
#
#   absorb-gate.sh template --triage <triage.json> [--registry-ref <ref>] [--registry <path>]
#                           [--cards <cards.json>] [--exclude-card CALA-N]...
#   absorb-gate.sh comment  --triage <triage.json> --decisions <decisions.yml>
#                           --verify <fork-verify out dir> --cards <cards.json>
#                           --candidate <rev>
#                           [--registry-ref <ref>] [--registry <path>] [--exclude-card CALA-N]...
#                           [--triage-md <md>] [--pr <url>] [--merge-commit <sha>]
#                           [--pr-check <url>] [--tag <planned tag>]
#
# template  Prints a decisions YAML skeleton to stdout (verdicts empty):
#           - candidates: one entry per C label (commit x feature) and per E
#             commit that is not already C (step 2).
#           - upstream_priority: one row per active/planned registry feature and
#             one row per open card that no registry feature lists (step 2-1).
#           The registry is read from --registry at --registry-ref (default: the
#           working file fork/features.yml). --cards is the JSON of
#           `multica issue list --project <id> --output json` (an object with
#           an `issues` key or a list). It must be the whole project list:
#           has_more true, offset > 0 and fewer unique issues than `total`
#           exit 2. Cards with status done/cancelled and
#           --exclude-card ids (repeatable, comma separated) get no row.
# comment   Takes the same inventory inputs as `template` and requires exact
#           coverage: every active/planned registry feature and every open,
#           non-excluded card outside the registry has exactly one
#           upstream_priority row; missing, duplicate and unknown ids exit 2.
#           --cards is required (an absorb always has project cards) and an
#           incomplete list is refused (template and comment): an incomplete
#           page cannot define the inventory.
#           --candidate <rev> is the commit that was verified and is up for
#           approval (the merge branch head). result.json's `sha` must equal
#           `git rev-parse <rev>^{commit}`, else exit 2. A --merge-commit that
#           differs from the candidate must have the same tree
#           (`<x>^{tree}`); if not, the first line holds the deploy
#           (`검증한 트리와 병합 커밋이 다름`). The deploy is also held when
#           result.json has no checks, or when an active registry feature has no
#           check in it (any verdict, n/a included): `검증 결과에 없는 개조 N건`.
#           Run it inside the fork checkout (the revs are resolved there).
#           Validates the decisions and prints the STOP comment (Korean markdown),
#           then a `--- attachments` line and one absolute path per line (the
#           triage .md and the screen captures, at most 8 files in total).
#           Exit 2 with the offending entries on stderr and nothing on stdout
#           when a verdict is empty or not allowed, or an input is unusable.
#
# Verdicts: candidate C 버림|줄임|유지; candidate E 흡수|보류|무관;
#           upstream_priority 상류로 대체|상류 위에 남은 것만|우리 것 유지|상류에 없음.
# No LLM, no network, same inputs give the same bytes. Exit 0 ok, 2 bad input.
set -uo pipefail

usage="usage: $0 template --triage <json> [--registry-ref <ref>] [--registry <path>] [--cards <json>] [--exclude-card CALA-N]...
       $0 comment  --triage <json> --decisions <yml> --verify <dir> --cards <json> --candidate <rev> [--registry-ref <ref>] [--registry <path>] [--exclude-card CALA-N]... [--triage-md <md>] [--pr <url>] [--merge-commit <sha>] [--pr-check <url>] [--tag <tag>]"
case "${1:-}" in
  template|comment) cmd="$1"; shift ;;
  -h|--help) echo "$usage"; exit 0 ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

if python3 -c 'import yaml' 2>/dev/null; then
  PY=(python3)
elif command -v uv >/dev/null 2>&1; then
  PY=(uv run -q --no-project --with pyyaml python3)
else
  echo "absorb-gate: PyYAML not available: install python3-yaml or uv" >&2
  exit 1
fi

# Buffer stdout so a validation failure never leaves a half comment.
out="$(mktemp "${TMPDIR:-/tmp}/absorb-gate.XXXXXX")" || { echo "absorb-gate: mktemp failed" >&2; exit 1; }
trap '/bin/rm -f "$out"' EXIT
"${PY[@]}" - "$cmd" "$@" > "$out" <<'PY'
import argparse
import json
import os
import subprocess
import sys

import yaml

C_VERDICTS = ("버림", "줄임", "유지")
E_VERDICTS = ("흡수", "보류", "무관")
P_VERDICTS = ("상류로 대체", "상류 위에 남은 것만", "우리 것 유지", "상류에 없음")
KEEP = "우리 것 유지"
CLOSED_CARD = ("done", "cancelled")
MAX_ATTACH = 8
UPSTREAM_PR_URL = "https://github.com/multica-ai/multica/pull/%s"

# fork_verify.py verdict values and their Korean labels.
PASS, FAIL, UNVERIFIED, NA = "pass", "fail", "unverified", "n/a"
VERDICT_KO = {PASS: "통과", FAIL: "실패", UNVERIFIED: "확인 불가", NA: "해당 없음"}
VERDICT_RANK = {FAIL: 0, UNVERIFIED: 1, PASS: 2, NA: 3}


def die(msg):
    sys.stderr.write("absorb-gate: %s\n" % msg)
    sys.exit(2)


def j(value):
    # JSON scalars and flow collections are valid YAML, so the skeleton can be
    # emitted without a YAML dumper (which would drop the allowed-value hints).
    return json.dumps(value, ensure_ascii=False)


def load_json(path, what):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except OSError:
        die("%s를 읽을 수 없습니다 (%s)" % (what, path))
    except ValueError:
        die("%s가 JSON이 아닙니다 (%s)" % (what, path))


def load_yaml_text(text, what):
    try:
        return yaml.safe_load(text)
    except yaml.YAMLError as exc:
        die("%s가 YAML이 아닙니다 (%s)" % (what, str(exc).splitlines()[0] if str(exc) else exc))


def load_triage(path):
    tri = load_json(path, "triage JSON")
    if not isinstance(tri, dict) or not isinstance(tri.get("commits"), list) or not tri.get("from") or not tri.get("to"):
        die("triage JSON에 from, to, commits가 없습니다 (%s)" % path)
    return tri


def short(sha):
    return str(sha)[:9]


def split_commits(tri):
    """C entries (commit x feature) and E-only commits, in triage order."""
    c_rows, e_rows = [], []
    for cm in tri["commits"]:
        labels = cm.get("labels") or {}
        sha = short(cm["sha"])
        cs = labels.get("C") or []
        for c in sorted(cs, key=lambda c: c.get("feature", "")):
            c_rows.append({
                "commit": sha, "pr": cm.get("pr"), "subject": cm.get("subject", ""),
                "feature": c["feature"], "status": c.get("status", ""), "cards": c.get("cards") or [],
                "drop_when": c.get("drop_when") or "", "evidence": c.get("evidence") or [],
            })
        if not cs and labels.get("E"):
            e_rows.append({"commit": sha, "pr": cm.get("pr"), "subject": cm.get("subject", ""), "areas": list(labels["E"])})
    return c_rows, e_rows


# ---------- template ----------

def repo_top():
    p = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else ""


def load_registry(a):
    if a.registry_ref:
        top = repo_top()
        if not top:
            die("--registry-ref는 git 저장소 안에서만 쓸 수 있습니다")
        p = subprocess.run(["git", "-C", top, "show", "%s:%s" % (a.registry_ref, a.registry)], capture_output=True, text=True)
        if p.returncode != 0:
            die("레지스트리를 읽을 수 없습니다 (%s:%s)" % (a.registry_ref, a.registry))
        text = p.stdout
    else:
        top = repo_top()
        cands = [a.registry] + ([os.path.join(top, a.registry)] if top and not os.path.isabs(a.registry) else [])
        path = next((c for c in cands if os.path.isfile(c)), "")
        if not path:
            die("레지스트리를 읽을 수 없습니다 (%s)" % a.registry)
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    doc = load_yaml_text(text, "레지스트리")
    if not isinstance(doc, dict) or not isinstance(doc.get("features"), list):
        die("레지스트리에 features 목록이 없습니다")
    return doc["features"]


def load_cards(path):
    """Open-card inventory. It must be the whole project list, not one page.

    `multica issue list --output json` prints {issues, total, limit, offset,
    has_more}. A later page (offset > 0) or a short one (fewer issues than
    total) would silently drop open cards, so both are refused. A bare list
    carries no paging fields and is taken as given.
    """
    data = load_json(path, "cards JSON")
    paging = None
    if isinstance(data, dict):
        paging = data
        if data.get("has_more") is True:
            die("cards JSON이 일부 페이지입니다 (has_more: true). --limit을 늘려 다시 받으세요 (%s)" % path)
        offset = data.get("offset", 0)
        if isinstance(offset, bool) or not isinstance(offset, int) or offset != 0:
            die("cards JSON이 첫 페이지가 아닙니다 (offset: %r). offset 0부터 전체를 합쳐 다시 받으세요 (%s)" % (offset, path))
        data = data.get("issues")
    if not isinstance(data, list):
        die("cards JSON은 목록이거나 issues 키를 가져야 합니다 (%s)" % path)
    cards = []
    for c in data:
        if not isinstance(c, dict) or not c.get("identifier"):
            die("cards JSON 항목에 identifier가 없습니다 (%s)" % path)
        cards.append({"id": str(c["identifier"]), "status": str(c.get("status", "")), "title": str(c.get("title", ""))})
    if paging is not None and "total" in paging:
        total = paging["total"]
        have = len({c["id"] for c in cards})
        if isinstance(total, bool) or not isinstance(total, int) or total != have:
            die("cards JSON의 카드 수가 total과 다릅니다 (카드 %d건, total %r). 전체를 받아 다시 넣으세요 (%s)" % (have, total, path))
    return cards


def card_sort_key(cid):
    head, _, tail = cid.rpartition("-")
    return (head, int(tail) if tail.isdigit() else 0, cid)


def inventory(a):
    """Registry features and open cards that need an upstream_priority row."""
    features = load_registry(a)
    cards = load_cards(a.cards) if a.cards else []
    excluded = {x.strip() for v in a.exclude_card for x in v.split(",") if x.strip()}
    registered = set()
    for f in features:
        registered.update(str(x) for x in (f.get("cards") or []))
    rows = [f for f in features if f.get("status") in ("active", "planned")]
    open_cards = [c for c in cards if c["status"] not in CLOSED_CARD and c["id"] not in registered and c["id"] not in excluded]
    open_cards.sort(key=lambda c: card_sort_key(c["id"]))
    return features, rows, open_cards


def cmd_template(a):
    tri = load_triage(a.triage)
    features, rows, open_cards = inventory(a)
    c_rows, e_rows = split_commits(tri)

    upstream = {}
    for c in c_rows:
        upstream.setdefault(c["feature"], []).append({"commit": c["commit"], "pr": c["pr"], "subject": c["subject"]})

    w = []
    w.append("# absorb-gate decisions. Fill every `verdict` (and the text field next to it);")
    w.append("# `absorb-gate.sh comment` refuses an empty or unknown value.")
    w.append("# candidates C: 버림 (drop ours, use upstream) | 줄임 (keep only what upstream lacks) | 유지 (keep ours); reason required.")
    w.append("# candidates E: 흡수 | 보류 | 무관; reason required.")
    w.append("# upstream_priority: 상류로 대체 | 상류 위에 남은 것만 | 우리 것 유지 | 상류에 없음; evidence required (PR, file, test result).")
    w.append("# 상류에 없음 = upstream ships nothing equivalent in this range; 우리 것 유지 = upstream overlaps but ours stays, and asks the user.")
    w.append("# `confirmed: true` on a 우리 것 유지 row records that the user already approved it; the comment then asks nothing.")
    w.append("target: %s" % j(tri["to"]))
    w.append("from: %s" % j(tri["from"]))
    if c_rows or e_rows:
        w.append("candidates:")
    else:
        w.append("candidates: []")
    for c in c_rows:
        w.append("  - kind: C")
        w.append("    commit: %s" % j(c["commit"]))
        w.append("    pr: %s" % j(c["pr"]))
        w.append("    subject: %s" % j(c["subject"]))
        w.append("    feature: %s" % j(c["feature"]))
        w.append("    cards: %s" % j(c["cards"]))
        w.append("    drop_when: %s" % j(c["drop_when"]))
        w.append("    evidence: %s" % j(c["evidence"]))
        w.append('    verdict: ""  # 버림|줄임|유지')
        w.append('    reason: ""')
    for e in e_rows:
        w.append("  - kind: E")
        w.append("    commit: %s" % j(e["commit"]))
        w.append("    pr: %s" % j(e["pr"]))
        w.append("    subject: %s" % j(e["subject"]))
        w.append("    areas: %s" % j(e["areas"]))
        w.append('    verdict: ""  # 흡수|보류|무관')
        w.append('    reason: ""')

    if rows or open_cards:
        w.append("upstream_priority:")
    else:
        w.append("upstream_priority: []")
    for f in rows:
        w.append("  - kind: feature")
        w.append("    id: %s" % j(f["id"]))
        w.append("    status: %s" % j(f.get("status")))
        w.append("    summary: %s" % j(str(f.get("summary", "")).strip()))
        w.append("    cards: %s" % j([str(x) for x in (f.get("cards") or [])]))
        ups = upstream.get(f["id"], [])
        if ups:
            w.append("    upstream:")
            for u in ups:
                w.append("      - %s" % j(u))
        else:
            w.append("    upstream: []")
        w.append('    verdict: ""  # 상류로 대체|상류 위에 남은 것만|우리 것 유지|상류에 없음')
        w.append('    evidence: ""')
        w.append('    action: ""')
    for c in open_cards:
        w.append("  - kind: card")
        w.append("    id: %s" % j(c["id"]))
        w.append("    status: %s" % j(c["status"]))
        w.append("    title: %s" % j(c["title"]))
        w.append('    verdict: ""  # 상류로 대체|상류 위에 남은 것만|우리 것 유지|상류에 없음')
        w.append('    evidence: ""')
        w.append('    action: ""')
    print("\n".join(w))


# ---------- comment ----------

def feature_verdict(verdicts):
    # Same semantics as fork_verify.feature_verdict.
    vs = set(verdicts)
    if FAIL in vs:
        return FAIL
    if UNVERIFIED in vs:
        return UNVERIFIED
    if vs == {NA} or not vs:
        return NA
    return PASS


def esc(value):
    return str(value if value is not None else "").replace("\\", "\\\\").replace("|", "\\|").replace("\r", " ").replace("\n", " ").strip()


def text(value):
    return "" if value is None else str(value).strip()


def pr_link(pr):
    return "-" if pr in (None, "") else "[#%s](%s)" % (pr, UPSTREAM_PR_URL % pr)


def check_decisions(dec, tri, expected):
    errs = []
    if not isinstance(dec, dict):
        die("decisions가 YAML 맵이 아닙니다")
    if text(dec.get("target")) != str(tri["to"]) or text(dec.get("from")) != str(tri["from"]):
        errs.append("target/from이 triage와 다릅니다 (decisions %s→%s, triage %s→%s)" % (dec.get("from"), dec.get("target"), tri["from"], tri["to"]))
    cands = dec.get("candidates") or []
    rows = dec.get("upstream_priority") or []
    if not isinstance(cands, list) or not isinstance(rows, list) or not all(isinstance(x, dict) for x in cands + rows):
        die("decisions의 candidates와 upstream_priority는 맵 목록이어야 합니다")

    c_rows, e_rows = split_commits(tri)
    have_c = {(text(x.get("commit"))[:9], text(x.get("feature"))) for x in cands if x.get("kind") == "C"}
    have_e = {text(x.get("commit"))[:9] for x in cands if x.get("kind") == "E"}
    for c in c_rows:
        if (c["commit"], c["feature"]) not in have_c:
            errs.append("candidates에 C 항목이 없습니다 (%s %s)" % (c["commit"], c["feature"]))
    for e in e_rows:
        if e["commit"] not in have_e:
            errs.append("candidates에 E 항목이 없습니다 (%s)" % e["commit"])

    for x in cands:
        kind = x.get("kind")
        who = "candidates %s %s" % (text(x.get("commit")), text(x.get("feature")) or kind)
        allowed = C_VERDICTS if kind == "C" else E_VERDICTS if kind == "E" else None
        if allowed is None:
            errs.append("%s kind는 C 또는 E여야 합니다" % who)
            continue
        v = text(x.get("verdict"))
        if not v:
            errs.append("%s verdict가 비어 있습니다 (%s)" % (who, "|".join(allowed)))
        elif v not in allowed:
            errs.append("%s verdict '%s'는 허용 값이 아닙니다 (%s)" % (who, v, "|".join(allowed)))
        elif not text(x.get("reason")):
            errs.append("%s reason이 비어 있습니다" % who)
    seen = {}
    for x in rows:
        if text(x.get("id")):
            seen[text(x.get("id"))] = seen.get(text(x.get("id")), 0) + 1
    for want in sorted(expected, key=card_sort_key):
        if want not in seen:
            errs.append("upstream_priority에 행이 없습니다 (%s)" % want)
    for got, n in sorted(seen.items(), key=lambda kv: card_sort_key(kv[0])):
        if got not in expected:
            errs.append("upstream_priority에 알 수 없는 id가 있습니다 (%s)" % got)
        elif n > 1:
            errs.append("upstream_priority에 id가 %d번 있습니다 (%s)" % (n, got))
    for x in rows:
        who = "upstream_priority %s" % text(x.get("id"))
        v = text(x.get("verdict"))
        if not text(x.get("id")):
            errs.append("upstream_priority 항목에 id가 없습니다")
        elif not v:
            errs.append("%s verdict가 비어 있습니다 (%s)" % (who, "|".join(P_VERDICTS)))
        elif v not in P_VERDICTS:
            errs.append("%s verdict '%s'는 허용 값이 아닙니다 (%s)" % (who, v, "|".join(P_VERDICTS)))
        elif not text(x.get("evidence")):
            errs.append("%s evidence가 비어 있습니다" % who)
    if errs:
        sys.stderr.write("absorb-gate: decisions가 완성되지 않았습니다 (%d건)\n" % len(errs))
        for e in errs:
            sys.stderr.write("  - %s\n" % e)
        sys.exit(2)
    return cands, rows


def resolve(rev, what, kind="commit"):
    top = repo_top()
    if not top:
        die("%s을 확인하려면 git 저장소 안에서 실행해야 합니다" % what)
    if not rev or rev.startswith("-"):
        die("%s가 올바른 리비전이 아닙니다 (%s)" % (what, rev))
    p = subprocess.run(["git", "-C", top, "rev-parse", "--verify", "-q", "%s^{%s}" % (rev, kind)], capture_output=True, text=True)
    if p.returncode != 0:
        die("%s를 찾을 수 없습니다 (%s)" % (what, rev))
    return p.stdout.strip()


def load_verify(vdir):
    path = os.path.join(vdir, "result.json")
    if not os.path.isfile(path):
        die("fork-verify 결과가 없습니다 (%s)" % path)
    res = load_json(path, "fork-verify result.json")
    if not isinstance(res, dict) or not isinstance(res.get("checks"), list) or "exit" not in res:
        die("fork-verify result.json에 exit와 checks가 없습니다 (%s)" % path)
    for c in res["checks"]:
        if not isinstance(c, dict) or c.get("verdict") not in VERDICT_KO or not c.get("feature") or not c.get("layer"):
            die("fork-verify result.json의 check 형식이 맞지 않습니다 (%s)" % path)
    return res


def pick_screens(vdir):
    sdir = os.path.join(vdir, "screens")
    names = sorted(os.listdir(sdir)) if os.path.isdir(sdir) else []
    regions = {n[: -len(".region.png")] for n in names if n.endswith(".region.png")}
    picked = []
    for n in names:
        if n.endswith(".region.png"):
            picked.append((n[: -len(".region.png")], n))
        elif n.endswith(".compare.png") and n[: -len(".compare.png")] not in regions:
            picked.append((n[: -len(".compare.png")], n))
    picked.sort()
    return [os.path.join(sdir, n) for _, n in picked]


def cmd_comment(a):
    tri = load_triage(a.triage)
    dec = load_yaml_text(open_text(a.decisions, "decisions"), "decisions")
    features, feats, open_cards = inventory(a)
    cands, rows = check_decisions(dec, tri, {f["id"] for f in feats} | {c["id"] for c in open_cards})
    res = load_verify(a.verify)
    candidate = resolve(a.candidate, "--candidate")
    if text(res.get("sha")) != candidate:
        die("fork-verify 결과가 후보와 다른 커밋을 검증했습니다 (result.json sha %s, --candidate %s = %s)" % (text(res.get("sha")) or "없음", a.candidate, candidate))
    tree_differs = False
    if a.merge_commit:
        merge_sha = resolve(a.merge_commit, "--merge-commit")
        if merge_sha != candidate:
            tree_differs = resolve(merge_sha, "--merge-commit", "tree") != resolve(candidate, "--candidate", "tree")
    if a.triage_md and not os.path.isfile(a.triage_md):
        die("triage 마크다운을 읽을 수 없습니다 (%s)" % a.triage_md)

    checks = res["checks"]
    count = {v: sum(1 for c in checks if c["verdict"] == v) for v in VERDICT_KO}
    exit_code = res["exit"]
    failed = exit_code != 0 or count[FAIL] > 0
    keep_rows = [r for r in rows if text(r.get("verdict")) == KEEP and r.get("confirmed") is not True]

    verified = {c["feature"] for c in checks}
    unverified_features = sorted(f["id"] for f in features if f.get("status") == "active" and f["id"] not in verified)

    reasons = []
    if tree_differs:
        reasons.append("검증한 트리와 병합 커밋이 다름")
    if not checks:
        reasons.append("검증 결과가 비어 있음")
    if unverified_features:
        reasons.append("검증 결과에 없는 개조 %d건 (%s)" % (len(unverified_features), ", ".join(unverified_features)))
    if failed:
        reasons.append("fork-verify 실패 %d건" % count[FAIL] if count[FAIL] else "fork-verify 종료 코드 %s" % exit_code)
    if count[UNVERIFIED]:
        reasons.append("확인 불가 %d건" % count[UNVERIFIED])
    if keep_rows:
        reasons.append("우리 것 유지 %d건 확인 필요" % len(keep_rows))

    w = []
    w.append("배포 보류: " + ", ".join(reasons) if reasons else "배포 준비 완료. 승인하면 배포합니다.")
    w.append("")

    # Summary
    w.append("**요약**")
    w.append("")
    w.append("- 상류 범위는 `%s`에서 `%s`까지입니다. merge를 뺀 커밋은 %d개입니다." % (tri["from"], tri["to"], len(tri["commits"])))
    merge = tri.get("merge")
    files = tri.get("conflict_files") or []
    if merge == "conflict":
        w.append("- 병합 충돌은 %d파일입니다. %s." % (len(files), ", ".join("`%s`" % f for f in files)))
    elif merge == "clean":
        w.append("- 병합 충돌은 없습니다.")
    elif merge == "already-merged":
        w.append("- 이 범위는 이미 병합되어 있습니다.")
    else:
        w.append("- 병합 충돌 여부를 확인하지 못했습니다.")
    migs = sorted(m["number"] for m in tri.get("migrations") or [])
    if migs:
        w.append("- 마이그레이션은 %d개입니다 (%d~%d). 적용하면 되돌릴 수 없어 배포 전에 백업합니다." % (len(migs), migs[0], migs[-1]))
    else:
        w.append("- 마이그레이션은 없습니다.")
    envs = tri.get("new_env") or []
    w.append("- 새 env 키는 %s입니다." % ", ".join("`%s`" % x for x in envs) if envs else "- 새 env 키는 없습니다.")
    clis = tri.get("new_cli") or []
    w.append("- 새 CLI 명령은 %s입니다." % ", ".join("`%s`" % x for x in clis) if clis else "- 새 CLI 명령은 없습니다.")
    gone = tri.get("removed_cli") or []
    if gone:
        w.append("- 사라진 CLI 명령은 %s입니다." % ", ".join("`%s`" % x for x in gone))
    if a.tag:
        w.append("- 배포 태그 `%s`" % a.tag)
    if a.pr:
        w.append("- PR %s" % a.pr)
    w.append("- 검증한 후보 `%s`" % candidate)
    if a.merge_commit:
        w.append("- 병합 커밋 `%s`" % a.merge_commit)
    if a.pr_check:
        w.append("- 로컬 검사 결과 %s" % a.pr_check)
    w.append("")

    # Upstream first
    w.append("**상류 우선 판정**")
    w.append("")
    if rows:
        w.append("| 대상 | 판정 | 근거 | 할 일 |")
        w.append("|---|---|---|---|")
        for r in rows:
            if r.get("kind") == "card":
                target = "%s %s" % (text(r.get("id")), text(r.get("title")))
            else:
                target = "`%s` (%s)" % (text(r.get("id")), text(r.get("status")))
                ups = [u for u in (r.get("upstream") or []) if isinstance(u, dict) and u.get("pr")]
                if ups:
                    target += " 상류 " + ", ".join("#%s" % u["pr"] for u in ups)
            w.append("| %s | %s | %s | %s |" % (esc(target), esc(r["verdict"]), esc(r.get("evidence")), esc(r.get("action")) or "-"))
    else:
        w.append("판정할 대상이 없습니다.")
    w.append("")

    # C/E candidates
    w.append("**C·E 후보 확정**")
    w.append("")
    if cands:
        w.append("| 커밋 | PR | 개조·영역 | 판정 | 이유 |")
        w.append("|---|---|---|---|---|")
        for x in cands:
            if x["kind"] == "C":
                area = "`%s`" % text(x.get("feature"))
                cards = [text(c) for c in (x.get("cards") or [])]
                if cards:
                    area += " (%s)" % ", ".join(cards)
            else:
                area = ", ".join(text(v) for v in (x.get("areas") or [])) or "-"
            w.append("| `%s` | %s | %s | %s | %s |" % (text(x.get("commit")), pr_link(x.get("pr")), esc(area), esc(x["verdict"]), esc(x.get("reason")) or "-"))
    else:
        w.append("확정할 후보가 없습니다.")
    w.append("")

    # Feature and screen tests
    w.append("**기능·화면 시험**")
    w.append("")
    by = {}
    for c in checks:
        by.setdefault(c["feature"], []).append(c)

    def cell(cs, layer):
        xs = [c for c in cs if c["layer"] == layer]
        if not xs:
            return "-"
        return "%s %d/%d" % (VERDICT_KO[feature_verdict(c["verdict"] for c in xs)], sum(1 for c in xs if c["verdict"] == PASS), len(xs))

    ordered = sorted(by, key=lambda f: (VERDICT_RANK[feature_verdict(c["verdict"] for c in by[f])], f))
    if ordered:
        w.append("| 개조 | 판정 | 시험 | 시나리오 | 화면 |")
        w.append("|---|---|---|---|---|")
        for f in ordered:
            cs = by[f]
            w.append("| `%s` | **%s** | %s | %s | %s |" % (f, VERDICT_KO[feature_verdict(c["verdict"] for c in cs)], cell(cs, "test"), cell(cs, "scenario"), cell(cs, "screen")))
        w.append("")
    w.append("합계 통과 %d, 실패 %d, 확인 불가 %d, 해당 없음 %d. fork-verify 종료 코드 %s." % (count[PASS], count[FAIL], count[UNVERIFIED], count[NA], exit_code))
    bad = [c for c in checks if c["verdict"] in (FAIL, UNVERIFIED)]
    if bad:
        w.append("")
        for c in sorted(bad, key=lambda c: (VERDICT_RANK[c["verdict"]], c["feature"], c["layer"], c.get("name", ""))):
            w.append("- `%s` %s %s. %s" % (c["feature"], VERDICT_KO[c["verdict"]], esc(c.get("name")), esc(c.get("detail"))))
    w.append("")

    # Screen comparison and attachments
    screens = pick_screens(a.verify)
    attach = []
    if a.triage_md:
        attach.append(os.path.abspath(a.triage_md))
    room = MAX_ATTACH - len(attach)
    shots = [os.path.abspath(p) for p in screens][:room]
    attach.extend(shots)
    w.append("**화면 비교**")
    w.append("")
    if shots:
        line = "운영 | 후보 | 차이 순서로 나란히 놓은 캡처 %d장을 이 댓글에 첨부합니다. %s." % (len(shots), ", ".join("`%s`" % os.path.basename(p) for p in shots))
        if len(screens) > len(shots):
            line += " 나머지 %d장은 fork-verify 출력 폴더에 있습니다." % (len(screens) - len(shots))
        w.append(line)
    else:
        w.append("첨부할 화면 캡처가 없습니다.")
    w.append("")

    # What approval triggers
    tag = a.tag or "<tag>"
    w.append("**승인하면 하는 일**")
    w.append("")
    w.append("승인 전에는 태그, 빌드, 배포를 하지 않습니다.")
    w.append("")
    w.append("1. 병합 커밋에 `%s` 태그를 답니다." % tag)
    w.append("2. 운영 DB를 `pg_dump`로 백업합니다.")
    w.append("3. `scripts/hoon/release.sh release %s`로 빌드하고 교체합니다." % tag)
    w.append("4. 운영에서 `scripts/hoon/fork-verify.sh %s --skip test,scenario`로 화면 시험을 다시 돌립니다." % tag)
    w.append("")
    w.append("되돌리기(`scripts/hoon/release.sh rollback`)는 이미지와 바이너리만 되돌립니다. 마이그레이션은 되돌리지 않습니다.")
    w.append("")
    w.append("Decide: 배포를 승인할까요?")
    for r in keep_rows:
        name = "`%s`" % text(r.get("id")) if r.get("kind") != "card" else "%s %s" % (text(r.get("id")), text(r.get("title")))
        w.append("Decide: %s 건은 우리 것을 그대로 유지할까요? 근거는 %s" % (name, text(r.get("evidence"))))
    w.append("")
    w.append("--- attachments")
    w.extend(attach)
    print("\n".join(w))


def open_text(path, what):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        die("%s를 읽을 수 없습니다 (%s)" % (what, path))


def main():
    ap = argparse.ArgumentParser(prog="absorb-gate.sh")
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("template")
    t.add_argument("--triage", required=True)
    t.add_argument("--registry-ref", default="")
    t.add_argument("--registry", default="fork/features.yml")
    t.add_argument("--cards", default="")
    t.add_argument("--exclude-card", action="append", default=[])
    c = sub.add_parser("comment")
    c.add_argument("--triage", required=True)
    c.add_argument("--decisions", required=True)
    c.add_argument("--verify", required=True)
    c.add_argument("--registry-ref", default="")
    c.add_argument("--registry", default="fork/features.yml")
    c.add_argument("--cards", required=True)
    c.add_argument("--candidate", required=True)
    c.add_argument("--exclude-card", action="append", default=[])
    c.add_argument("--triage-md", default="")
    c.add_argument("--pr", default="")
    c.add_argument("--merge-commit", default="")
    c.add_argument("--pr-check", default="")
    c.add_argument("--tag", default="")
    a = ap.parse_args()
    try:
        {"template": cmd_template, "comment": cmd_comment}[a.cmd](a)
    except (KeyError, TypeError, AttributeError, ValueError) as exc:
        die("입력 형식이 맞지 않습니다 (%s: %s)" % (type(exc).__name__, exc))


main()
PY
rc=$?
if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi
cat "$out"

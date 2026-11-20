#!/usr/bin/env bash
# Tests for scripts/hoon/fork-verify.sh: the judging and planning functions in
# fork-verify/fork_verify.py against fixed inputs, plus the wrapper's argument
# handling and the candidate-commit check on a throwaway repository. No stack,
# no browser, no network.
#   bash scripts/hoon/fork-verify.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if python3 -c 'import yaml, PIL' 2>/dev/null; then
  PY=(python3)
else
  PY=(uv run -q --no-project --with pyyaml --with pillow python3)
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/fork-verify-test.XXXXXX")"
trap '/bin/rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

fail=0
out="$(bash "$HERE/fork-verify.sh" 2>&1)"; rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q 'usage'; then echo "ok   no ref: usage, exit 2"; else echo "FAIL no ref: exit $rc"; fail=1; fi
out="$(bash "$HERE/fork-verify.sh" no-such-ref-xyz --skip test,scenario,screen 2>&1)"; rc=$?
if [ "$rc" = 2 ]; then echo "ok   unknown ref: exit 2"; else echo "FAIL unknown ref: exit $rc ($out)"; fail=1; fi

FV_TMP="$T" "${PY[@]}" - "$HERE/fork-verify" <<'PY' || fail=1
import json, os, subprocess, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import fork_verify as fv
from PIL import Image, ImageDraw

T = Path(os.environ["FV_TMP"])
failed = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        failed.append(name)

# --- verdict roll-up and exit code
C = fv.Check
check("feature verdict: any fail wins", fv.feature_verdict([C("a", "test", "x", fv.PASS, ""), C("a", "test", "y", fv.FAIL, "")]) == fv.FAIL)
check("feature verdict: unverified beats pass", fv.feature_verdict([C("a", "test", "x", fv.PASS, ""), C("a", "screen", "y", fv.UNVERIFIED, "")]) == fv.UNVERIFIED)
check("feature verdict: all n/a", fv.feature_verdict([C("a", "test", "x", fv.NA, "")]) == fv.NA)
check("exit 1 on a fail", fv.exit_code([C("a", "test", "x", fv.FAIL, "")]) == 1)
check("exit 0 with unverified only", fv.exit_code([C("a", "test", "x", fv.UNVERIFIED, ""), C("b", "test", "x", fv.PASS, "")]) == 0)

# --- go test output
go_out = """=== RUN   TestA
--- PASS: TestA (0.01s)
=== RUN   TestB
    --- FAIL: TestB/sub (0.00s)
--- FAIL: TestB (0.00s)
--- SKIP: TestC (0.00s)
"""
r = fv.parse_go_test_output(go_out, ["TestA", "TestB", "TestC", "TestD"])
check("go: pass/fail/skip/missing", r == {"TestA": "PASS", "TestB": "FAIL", "TestC": "SKIP", "TestD": None})

# --- vitest json
data = {"testResults": [{"name": "/x/packages/views/chat/components/chat-bar.test.tsx", "status": "passed", "assertionResults": [
    {"title": "shows a chip for every chat", "fullName": "ChatBar shows a chip for every chat", "status": "passed"},
    {"title": "scrolls", "fullName": "ChatBar scrolls", "status": "failed"}]}]}
check("vitest: named case passes", fv.parse_vitest_json(data, None, "packages/views/chat/components/chat-bar.test.tsx", "shows a chip for every chat")[0] == fv.PASS)
check("vitest: named failing case fails", fv.parse_vitest_json(data, None, "packages/views/chat/components/chat-bar.test.tsx", "scrolls")[0] == fv.FAIL)
check("vitest: missing case fails", fv.parse_vitest_json(data, None, "packages/views/chat/components/chat-bar.test.tsx", "nope")[0] == fv.FAIL)
check("vitest: whole file with a failure fails", fv.parse_vitest_json(data, None, "packages/views/chat/components/chat-bar.test.tsx", None)[0] == fv.FAIL)
check("vitest: file that failed to load fails", fv.parse_vitest_json({"testResults": [{"name": "/x/a.test.ts", "status": "failed", "message": "SyntaxError", "assertionResults": []}]}, None, "a.test.ts", None)[0] == fv.FAIL)
hook = {"testResults": [{"name": "/x/a.test.ts", "status": "failed", "message": "afterAll hook failed", "assertionResults": [{"title": "t", "fullName": "t", "status": "passed"}]}]}
check("vitest: failed file with passing cases fails (hook error)", fv.parse_vitest_json(hook, None, "a.test.ts", "t")[0] == fv.FAIL)
mixed = {"testResults": [{"name": "/x/a.test.ts", "status": "failed", "assertionResults": [{"title": "ok", "fullName": "ok", "status": "passed"}, {"title": "bad", "fullName": "bad", "status": "failed"}]}]}
both = {"testResults": [{"name": "/x/a.test.ts", "status": "failed", "message": "afterAll hook failed", "assertionResults": [{"title": "ok", "fullName": "ok", "status": "passed"}, {"title": "bad", "fullName": "bad", "status": "failed"}]}]}
check("vitest: file-level error fails passing cases even next to a failing case", fv.parse_vitest_json(both, None, "a.test.ts", "ok")[0] == fv.FAIL)
check("vitest: a passing case next to a failing one still passes", fv.parse_vitest_json(mixed, None, "a.test.ts", "ok")[0] == fv.PASS)
check("vitest: all skipped fails", fv.parse_vitest_json({"testResults": [{"name": "/x/a.test.ts", "status": "passed", "assertionResults": [{"title": "t", "status": "skipped"}]}]}, None, "a.test.ts", None)[0] == fv.FAIL)
check("vitest: file not run fails", fv.parse_vitest_json(data, None, "packages/views/layout/bottom-bar.test.tsx", None)[0] == fv.FAIL)

# --- resident run judging
root = T / "task-root"
root.mkdir()
ls_out = "terminal result\n.\n..\n.managed_env.json\n.multica_resident_task.json\n.task_lock\n.task_owner\nlogs\nworkdir"
status = 'terminal result\n- **output:**   "cli_version": "0.11.0-hoon.1",\n  "status": "running",\n- **exit_code:** 0'
outputs = ['terminal result\n- **output:**   "identifier": "FV-1",\n  "status": "backlog",', status, status, status,
           "Checked out https://github.com/honki12345/multica → /w/multica (branch: agent/fv-resident/abc)", "No environments.", ls_out]
comments = [{"author_type": "agent", "author_id": "agent-1", "content": "done"}]
got = {fid: v for fid, _, v, _ in fv.judge_resident(outputs, "0.11.0-hoon.1", "FV-1", root, comments, "agent-1")}
check("resident: healthy run passes all four", got == {k: fv.PASS for k in ("resident-hermes-gateway", "resident-no-hermes-home-overlay",
                                                                             "resident-daemon-local-commands", "resident-daemon-status")})
stopped = list(outputs)
stopped[2] = status.replace("running", "stopped")
got = {fid: v for fid, _, v, _ in fv.judge_resident(stopped, "0.11.0-hoon.1", "FV-1", root, comments, "agent-1")}
check("resident: one stopped daemon status fails", got["resident-daemon-status"] == fv.FAIL)
missing = [o for o in outputs if "cli_version" not in o]
got = {fid: v for fid, _, v, _ in fv.judge_resident(missing, "0.11.0-hoon.1", "FV-1", root, comments, "agent-1")}
check("resident: no daemon status output fails", got["resident-daemon-status"] == fv.FAIL)
got = {fid: v for fid, _, v, _ in fv.judge_resident(outputs[:2] + outputs[4:], "0.11.0-hoon.1", "FV-1", root, comments, "agent-1")}
check("resident: one running daemon status passes", got["resident-daemon-status"] == fv.PASS)
usage = [o if "No environments" not in o else "Usage: multica environment [command]\nNAMESPACE flags" for o in outputs]
got = {fid: v for fid, _, v, _ in fv.judge_resident(usage, "0.11.0-hoon.1", "FV-1", root, comments, "agent-1")}
check("resident: environment usage text is not a successful list", got["resident-daemon-local-commands"] == fv.FAIL)
got = {fid: v for fid, _, v, _ in fv.judge_resident(outputs, "0.11.0-hoon.1", "FV-1", None, comments, "agent-1")}
check("resident: unknown task root (no work dir) fails, not 'removed'", got["resident-hermes-gateway"] == fv.FAIL and got["resident-no-hermes-home-overlay"] == fv.FAIL)
got = {fid: v for fid, _, v, _ in fv.judge_resident(outputs, "0.11.0-hoon.2", "FV-1", root, comments, "agent-1")}
check("resident: daemon of another version fails", got["resident-daemon-status"] == fv.FAIL)
overlay = list(outputs)
overlay[-1] = ls_out + "\nhermes-home"
got = {fid: v for fid, _, v, _ in fv.judge_resident(overlay, "0.11.0-hoon.1", "FV-1", root, comments, "agent-1")}
check("resident: hermes-home in the task root fails", got["resident-no-hermes-home-overlay"] == fv.FAIL)
port = list(outputs)
port[4] = "Error: MULTICA_DAEMON_PORT not set"
got = {fid: v for fid, _, v, _ in fv.judge_resident(port, "0.11.0-hoon.1", "FV-1", root, comments, "agent-1")}
check("resident: repo checkout port error fails", got["resident-daemon-local-commands"] == fv.FAIL)
got = {fid: v for fid, _, v, _ in fv.judge_resident(outputs, "0.11.0-hoon.1", "FV-1", root, [{"author_type": "member", "author_id": "u"}], "agent-1")}
check("resident: comment by the member, not the agent, fails", got["resident-hermes-gateway"] == fv.FAIL)
(root / ".multica_resident_task.json").write_text("{}")
got = {fid: v for fid, _, v, _ in fv.judge_resident(outputs, "0.11.0-hoon.1", "FV-1", root, comments, "agent-1")}
check("resident: context file left after the run fails", got["resident-hermes-gateway"] == fv.FAIL)

# --- shot planning
features = [{"id": "chat-bar-all-chips", "kind": "web-ui", "scenarios": [
    {"name": "every chip visible, strip scrolls", "path": "/<workspace-slug>/issues", "widths": [1440, 900],
     "steps": ["Open", "Click the right-most chip."], "selectors": ['[data-slot="chat-bar"]']},
    {"name": "bar hidden on a narrow window", "path": "/<workspace-slug>/issues", "widths": [700], "steps": ["Open the page."], "selectors": []}]},
    {"id": "inbox-list-filters", "kind": "cli"}]
shots = fv.plan_shots(features, "acme")
check("shots: two widths + one narrow", [(s["width"], s["scenarioIndex"]) for s in shots] == [(1440, 0), (900, 0), (700, 1)])
check("shots: slug substituted", all(s["path"] == "/acme/issues" for s in shots))
check("shots: only the click scenario interacts", [s["interact"] for s in shots] == [True, True, False])
si = {"screen_inputs": [{"feature": "chat-bar-all-chips", "paths": ["packages/views/chat/components/chat-input.tsx", "packages/core/chat/queries.ts",
                                                                     "packages/views/layout/dashboard-layout.tsx"]},
                        {"feature": "inbox-list-filters", "paths": ["packages/core/inbox/filters.ts"]}]}
extra = [s for s in fv.plan_shots(features, "acme", si) if s["scenarioIndex"] == -1]
check("screen input: B routes for web-ui features only, deduped", [s["path"] for s in extra] == ["/acme/chat"])

# --- chat bar judging
def res(cand, prod=None, url="/acme/issues", page=True):
    return {"cand": {"probe": cand, "error": None, "url": url, "page": page}, "prod": {"probe": prod or cand, "error": None}}
full = {"bar": 1, "chips": 12, "overflowButtons": 0, "strip": True, "stripScrollable": True, "wheelScrolled": True,
        "teamStatusKeptWidth": True, "windowOpen": True, "clickedChipInView": True}
s1 = shots[0]
check("chat bar: all chips, no +N, interactions ok", fv.judge_chat_bar(s1, res(full), 12)[0] == fv.PASS)
folded = dict(full, overflowButtons=1)
v, d = fv.judge_chat_bar(s1, res(folded), 12)
check("chat bar: +N menu fails even when every chip shows", v == fv.FAIL and d.startswith("+N 버튼"))
check("chat bar: missing chips fail", fv.judge_chat_bar(s1, res(dict(full, chips=4)), 12)[0] == fv.FAIL)
check("chat bar: wheel not scrolling fails", fv.judge_chat_bar(s1, res(dict(full, wheelScrolled=False)), 12)[0] == fv.FAIL)
check("chat bar: narrow window must hide the bar", fv.judge_chat_bar(shots[2], res({"bar": 1}), 12)[0] == fv.FAIL)
check("chat bar: candidate redirected to /login fails", fv.judge_chat_bar(shots[2], res({"bar": 0}, url="/login", page=False), 12)[0] == fv.FAIL)
check("chat bar: candidate without a page body fails", fv.judge_chat_bar(s1, res(full, page=False), 12)[0] == fv.FAIL)
check("chat bar: narrow window without bar passes", fv.judge_chat_bar(shots[2], res({"bar": 0}), 12)[0] == fv.PASS)

# --- pixel diff and triptych
a = Image.new("RGB", (200, 100), (255, 255, 255))
b = a.copy()
ImageDraw.Draw(b).rectangle([0, 0, 19, 9], fill=(0, 0, 0))
check("diff ratio: 200 of 20000 pixels", abs(fv.diff_ratio(a, b) - 0.01) < 1e-9)
check("diff ratio: identical is 0", fv.diff_ratio(a, a.copy()) == 0.0)
check("diff ratio: region box", abs(fv.diff_ratio(a, b, (0, 0, 20, 10)) - 1.0) < 1e-9)
check("diff ratio: tiny noise under tolerance ignored", fv.diff_ratio(a, Image.new("RGB", (200, 100), (250, 250, 250))) == 0.0)
a.save(T / "a.png"); b.save(T / "b.png")
fv.triptych(T / "a.png", T / "b.png", T / "c.png")
im = Image.open(T / "c.png")
check("triptych: three panels side by side", im.size == (200 * 3 + 16, 100 + 22))
check("triptych: diff panel marks the change red", im.getpixel((2 * 208 + 5, 22 + 5)) == (230, 30, 30))

# --- candidate commit check on a throwaway repo
repo = T / "repo"
subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True)
def commit(msg):
    (repo / "f").write_text(msg)
    subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(repo), "commit", "-qm", msg], check=True)
    return subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
old = commit("base")
feat = commit("feature")
fv.REPO = repo
check("in candidate: feature commit present", fv.feature_in_candidate({"origin": {"commits": [feat[:9]]}}, feat))
check("in candidate: older candidate lacks it", not fv.feature_in_candidate({"origin": {"commits": [feat[:9]]}}, old))
check("in candidate: no commits listed counts as present", fv.feature_in_candidate({"origin": {}}, old))

check("version: hoon tag", fv.resolve_version("v0.11.0-hoon.1", "", "abc") == "0.11.0-hoon.1")

# --- run_vitest with a stub pnpm: passing JSON but vitest exits 1 (unhandled error)
stub = T / "stubbin"
stub.mkdir()
(stub / "pnpm").write_text("""#!/bin/sh
[ "$1" = install ] && exit 0
for a in "$@"; do case "$a" in --outputFile=*) out="${a#--outputFile=}";; esac; done
printf '%s' '{"numFailedTests":0,"testResults":[{"name":"/t/packages/views/a.test.ts","status":"passed","assertionResults":[{"title":"t","fullName":"t","status":"passed"}]}]}' > "$out"
exit "${STUB_EXIT:-1}"
""")
(stub / "pnpm").chmod(0o755)
tree = T / "tree"
(tree / "packages" / "views").mkdir(parents=True)
logs = T / "vlogs"
logs.mkdir()
feat_v = [{"id": "f", "tests": [{"vitest": "packages/views/a.test.ts", "name": "t"}]}]
env = dict(os.environ, PATH="%s:%s" % (stub, os.environ["PATH"]))
v = fv.run_vitest(tree, feat_v, dict(env, STUB_EXIT="1"), logs)
check("run_vitest: unexplained non-zero exit fails a passing entry", [c.verdict for c in v] == [fv.FAIL])
v = fv.run_vitest(tree, feat_v, dict(env, STUB_EXIT="0"), logs)
check("run_vitest: clean exit keeps the pass", [c.verdict for c in v] == [fv.PASS])
check("version: untagged branch uses the describe form the CLI gates accept", fv.resolve_version(feat, "", feat[:9]) == "0.0.0-0-g%s" % feat[:9])
subprocess.run(["git", "-C", str(repo), "tag", "v0.11.0", old], check=True)
v = fv.resolve_version(feat, "", feat[:9])
check("version: commit past a tag reports git describe (%s)" % v, v.startswith("v0.11.0-1-g"))
sys.exit(1 if failed else 0)
PY
[ "$fail" = 0 ] && echo "fork-verify.test: all passed" || { echo "fork-verify.test: FAILED"; exit 1; }

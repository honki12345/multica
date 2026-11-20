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

# --- prompt navigation: fixture, shot planning, judging
fx = fv.chat_fixture()
sid1, sid2 = fv.fixture_session_id(1), fv.fixture_session_id(2)
plain, wake = fx["messages"][sid1], fx["messages"][sid2]
check("fixture: plain chat has six sent messages with long replies between", [m["role"] for m in plain].count("user") == 6
      and all(len(m["content"]) > 3000 for m in plain if m["role"] == "assistant")
      and [m["role"] for m in plain] == ["user", "assistant"] * 6)
check("fixture: wakeup chat has two wakeup turns with task ids",
      [(m["message_kind"], bool(m["task_id"])) for m in wake if m["message_kind"] == "wakeup"] == [("wakeup", True)] * 2
      and all(m["role"] == "user" for m in wake if m["message_kind"] == "wakeup"))
check("fixture: rows carry what ChatMessageSchema needs", all({"id", "chat_session_id", "role", "content", "created_at", "message_kind"} <= set(m)
      and m["chat_session_id"] in (sid1, sid2) for ms in fx["messages"].values() for m in ms)
      and len({m["id"] for ms in fx["messages"].values() for m in ms}) == len(plain) + len(wake))
check("fixture: only two chats have a transcript, the list is unchanged", len(fx["sessions"]) == fv.FIXTURE_CHATS and len(fx["messages"]) == 2)
check("stops: sent messages oldest first, wakeups as dividers", fv.prompt_nav_stops(wake) ==
      ["fv-prompt-01", "fv-prompt-02", "divider", "fv-prompt-03", "fv-prompt-04", "divider", "fv-prompt-05", "fv-prompt-06"])

pn_feature = {"id": "chat-prompt-navigation", "kind": "web-ui", "scenarios": [
    {"name": n, "path": pth, "widths": [1440], "steps": ["Click into the composer."], "selectors": ['[data-chat-prompt-nav]']}
    for n, pth in (("step through sent messages", "/<workspace-slug>/chat"), ("floating window takes the keys while focused", "/<workspace-slug>/issues"),
                   ("stop at wakeup dividers", "/<workspace-slug>/chat"), ("listed in Settings", "/<workspace-slug>/settings"),
                   ("a scenario nobody wrote a runner for", "/<workspace-slug>/chat"))]}
pn = {s["scenario"]: s for s in fv.plan_shots([pn_feature], "acme")}
s1, s2, s3 = pn["step through sent messages"], pn["floating window takes the keys while focused"], pn["stop at wakeup dividers"]
check("plan: chat page shot opens the fixture session", s1["probe"] == "prompt-nav" and s1["path"] == "/acme/chat?session=" + sid1
      and s1["promptNav"]["listSelector"] == "[data-chat-prompt-nav]" and len(s1["promptNav"]["expect"]) == 6)
check("plan: wakeup shot opens the wakeup chat", s3["path"] == "/acme/chat?session=" + sid2 and s3["promptNav"]["expect"].count("divider") == 2)
check("plan: floating window shot opens it through localStorage, scoped to the workspace",
      s2["path"] == "/acme/issues" and s2["localStorage"] == {"multica:chat:isOpen": "true", "multica:chat:activeSessionId:acme": sid1}
      and s2["promptNav"]["listSelector"] == '[data-mc="chat-window"] [data-chat-prompt-nav]')
check("plan: Settings scenario keeps the plain open-and-look check", pn["listed in Settings"]["probe"] is None and "promptNav" not in pn["listed in Settings"])
check("plan: a scenario without a runner is marked, not silently opened", pn["a scenario nobody wrote a runner for"]["probe"] == "no-runner")
check("shots: the ?session query does not stop screen-input dedupe of the plain chat route",
      [s["path"] for s in fv.plan_shots([pn_feature], "acme", {"screen_inputs": [{"feature": "chat-prompt-navigation", "paths": ["packages/views/chat/chat-page.tsx"]}]}) if s["scenarioIndex"] == -1] == [])

def pn_res(shot, back, fwd, rows=12, url=None, error=None, focused=True, kept=True):
    probe = {"list": 1, "rows": rows, "composerFocused": focused, "focusKept": kept, "back": back, "forward": fwd}
    return {"cand": {"probe": probe, "error": error, "url": url or shot["path"].split("?")[0], "page": True}, "prod": {"probe": probe, "error": None}}
def going_back(tokens):
    """Probe rows for pressing [ once per stop: newest first, row index falling."""
    n = len(tokens)
    return [{"kind": "divider" if t == "divider" else "user", "token": t, "index": 2 * (n - 1 - i), "offset": 0} for i, t in enumerate(tokens[::-1])]
exp1 = s1["promptNav"]["expect"]
back1 = going_back(exp1)
fwd1 = back1[::-1][1:]
check("prompt nav: every press on a sent message, in order both ways", fv.judge_prompt_nav(s1, pn_res(s1, back1, fwd1))[0] == fv.PASS)
reply = [dict(back1[0])] + [dict(back1[1], kind="reply", token=None)] + back1[2:]
v, d = fv.judge_prompt_nav(s1, pn_res(s1, reply, fwd1))
check("prompt nav: a reply at the top after a press fails", v == fv.FAIL and "2번째" in d)
check("prompt nav: wrong order fails", fv.judge_prompt_nav(s1, pn_res(s1, back1[::-1], fwd1))[0] == fv.FAIL)
check("prompt nav: forward that does not move fails", fv.judge_prompt_nav(s1, pn_res(s1, back1, [dict(fwd1[0])] * len(fwd1)))[0] == fv.FAIL)
check("prompt nav: forward that stops short fails", fv.judge_prompt_nav(s1, pn_res(s1, back1, fwd1[:2]))[0] == fv.FAIL)
check("prompt nav: no presses registered fails", fv.judge_prompt_nav(s1, pn_res(s1, [], []))[0] == fv.FAIL)
v, d = fv.judge_prompt_nav(s1, pn_res(s1, back1, fwd1, rows=0))
check("prompt nav: empty list (fixture chat not opened) fails with that reason", v == fv.FAIL and "메시지 행이 없음" in d)
check("prompt nav: a composer that never got focus fails", fv.judge_prompt_nav(s1, pn_res(s1, back1, fwd1, focused=False))[0] == fv.FAIL)
check("prompt nav: caret leaving the composer fails", fv.judge_prompt_nav(s1, pn_res(s1, back1, fwd1, kept=False))[0] == fv.FAIL)
check("prompt nav: candidate error fails", fv.judge_prompt_nav(s1, pn_res(s1, back1, fwd1, error="boom"))[0] == fv.FAIL)
check("prompt nav: redirected away fails", fv.judge_prompt_nav(s1, pn_res(s1, back1, fwd1, url="/login"))[0] == fv.FAIL)
exp3 = s3["promptNav"]["expect"]
back3 = going_back(exp3)
fwd3 = back3[::-1][1:]
check("prompt nav: wakeup dividers count as stops", fv.judge_prompt_nav(s3, pn_res(s3, back3, fwd3, rows=16))[0] == fv.PASS)
skipped = [r for r in back3 if r["kind"] != "divider"]
check("prompt nav: skipping the wakeup dividers fails", fv.judge_prompt_nav(s3, pn_res(s3, skipped, fwd3, rows=16))[0] == fv.FAIL)

check("plan: the probe gets the judge's alignment tolerance", s1["promptNav"]["alignPx"] == fv.PROMPT_NAV_ALIGN_PX)
check("plan: the probe re-counts the scenario's selectors while it steps (virtualized rows)", s1["promptNav"]["selectors"] == s1["selectors"] == ['[data-chat-prompt-nav]'])
clipped = [dict(r, offset=-30) for r in back1]
v, d = fv.judge_prompt_nav(s1, pn_res(s1, clipped, fwd1))
check("prompt nav: right rows clipped 30px above the top fail", v == fv.FAIL and "맨 위에 맞지 않음" in d)
below = [dict(r, offset=200) for r in fwd1]
check("prompt nav: right rows left below the top fail", fv.judge_prompt_nav(s1, pn_res(s1, back1, below))[0] == fv.FAIL)
unsettled = [dict(back1[0], offset=None)] + back1[1:]
check("prompt nav: a press that never settled fails", fv.judge_prompt_nav(s1, pn_res(s1, unsettled, fwd1))[0] == fv.FAIL)
check("prompt nav: within the tolerance passes", fv.judge_prompt_nav(s1, pn_res(s1, [dict(r, offset=-fv.PROMPT_NAV_ALIGN_PX) for r in back1], fwd1))[0] == fv.PASS)

sel_missing = {"cand": {"selectors": {"[data-chat-prompt-nav]": 0}, "probe": None, "error": None}, "prod": {}}
check("judge_shot: no runner is unverified even with missing selectors", fv.judge_shot(pn["a scenario nobody wrote a runner for"], sel_missing)[0] == fv.UNVERIFIED)
res_ok = pn_res(s1, back1, fwd1)
res_ok["cand"]["selectors"] = {"[data-chat-prompt-nav]": 0}
check("judge_shot: a missing selector still fails a passing probe", fv.judge_shot(s1, res_ok)[0] == fv.FAIL)
res_ok["cand"]["selectors"] = {"[data-chat-prompt-nav]": 1}
check("judge_shot: prompt-nav probe goes through the judge", fv.judge_shot(s1, res_ok)[0] == fv.PASS)

no_runner = fv.judge_shot(pn["a scenario nobody wrote a runner for"], sel_missing)
check("shot verdict: a big pixel diff never turns a no-runner shot into a fail", fv.shot_verdict(no_runner, 0.5, 0.5, 0.01)[0] == fv.UNVERIFIED)
check("shot verdict: a big pixel diff fails a judged shot", fv.shot_verdict((fv.PASS, "ok"), 0.5, 0.5, 0.01)[0] == fv.FAIL)
check("shot verdict: a small pixel diff keeps the judged verdict", fv.shot_verdict((fv.PASS, "ok"), 0.001, 0.2, 0.01)[0] == fv.PASS)

# --- go test DB: the candidate's migrated test DB, or unverified with a reason
check("go db: ok state never explains a failure away", fv.go_db_unavailable("Failed to connect to handler test database configured by DATABASE_URL", "ok") is None)
check("go db: failed migration + connection failure is the DB, not the feature",
      "multica_gotest" in (fv.go_db_unavailable("Failed to connect to handler test database configured by DATABASE_URL\nFAIL", "failed") or ""))
check("go db: no stack + skipped package is unverified", fv.go_db_unavailable("Skipping tests: could not connect to database", "no-stack") is not None)
check("go db: a real test failure is not blamed on the DB", fv.go_db_unavailable("--- FAIL: TestX (0.00s)\n    x_test.go:1: nope", "failed") is None)
go_stub = T / "gostub"
go_stub.mkdir()
(go_stub / "go").write_text("#!/bin/sh\ncat \"$GO_STUB_OUT\"\nexit \"${GO_STUB_RC:-1}\"\n")
(go_stub / "go").chmod(0o755)
gtree = T / "gotree"
(gtree / "server").mkdir(parents=True)
glogs = T / "golog"
glogs.mkdir()
go_feat = [{"id": "chat-pinned-reorder", "tests": [{"go": "server/internal/handler", "name": "TestReorderPinnedChatSessions_SavesOrderWithoutTouchingActivity"}]}]
def go_run(output, db, rc="1"):
    (T / "go.out").write_text(output)
    e = dict(os.environ, PATH="%s:%s" % (go_stub, os.environ["PATH"]), GO_STUB_OUT=str(T / "go.out"), GO_STUB_RC=rc)
    return [c.verdict for c in fv.run_go_tests(gtree, go_feat, e, glogs, False, {}, db)]
no_db_out = "Failed to connect to handler test database configured by DATABASE_URL\nFAIL\tgithub.com/x/handler\t0.1s\n"
check("run_go_tests: failed test DB migration reports unverified, not fail", go_run(no_db_out, "failed") == [fv.UNVERIFIED])
check("run_go_tests: no stack reports unverified", go_run(no_db_out, "no-stack") == [fv.UNVERIFIED])
fixture_out = 'Failed to set up handler test fixture: ERROR: relation "workspace" does not exist (SQLSTATE 42P01)\nFAIL\tgithub.com/x/handler\t0.6s\n'
check("run_go_tests: a fixture failure on a DB said to be migrated still fails", go_run(fixture_out, "ok") == [fv.FAIL])
check("run_go_tests: a passing test passes", go_run("--- PASS: TestReorderPinnedChatSessions_SavesOrderWithoutTouchingActivity (0.01s)\nPASS\n", "ok", "0") == [fv.PASS])
check("run_go_tests: a failing test stays a fail when the DB is unavailable but reachable output is a real failure",
      go_run("--- FAIL: TestReorderPinnedChatSessions_SavesOrderWithoutTouchingActivity (0.01s)\nFAIL\n", "failed") == [fv.FAIL])
mixed_out = ("Failed to connect to handler test database configured by DATABASE_URL\n"
             "--- FAIL: TestReorderPinnedChatSessions_SavesOrderWithoutTouchingActivity (0.01s)\nFAIL\n")
check("run_go_tests: an explicit FAIL next to a DB marker stays a fail", go_run(mixed_out, "failed") == [fv.FAIL])
check("run_go_tests: a test that never ran next to a DB marker is unverified",
      go_run("Failed to connect to handler test database configured by DATABASE_URL\nFAIL\n", "no-stack") == [fv.UNVERIFIED])
st = fv.Stack(type("A", (), {"host": "h", "port_base": 100, "repo_url": ""})(), "sha", "sha7", "0.1.0", "sha7", T)
check("stack: no up means no test DB", st.gotest_db_state() == "no-stack")
st.up_ok = True
check("stack: up without gotest_db=ok means failed", st.gotest_db_state() == "failed" and st.gotest_db_url() == "")
st.info["gotest_db"] = "failed"
check("stack: gotest_db=failed means failed", st.gotest_db_state() == "failed")
st.info["gotest_db"] = "ok"
check("stack: gotest_db=ok means ok", st.gotest_db_state() == "ok")

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

# --- leftover processes of the test HERMES_HOME are stopped; others are not
import time as _t
hh = str(T / "hh" / ".hermes")
# Not /bin/sleep: macOS hides the environment of platform binaries from ps -E.
nap = [sys.executable, "-c", "import time; time.sleep(60)"]
mine = subprocess.Popen(nap, env=dict(os.environ, HERMES_HOME=hh))
other = subprocess.Popen(nap, env=dict(os.environ, HERMES_HOME=hh + "-other"))
_t.sleep(0.3)
fv.stop_processes_with_env("HERMES_HOME", hh)
_t.sleep(0.3)
check("cleanup: process with the test HERMES_HOME stopped", mine.poll() is not None)
check("cleanup: process with another HERMES_HOME untouched", other.poll() is None)
other.kill()

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
(stub / "pnpm").write_text((stub / "pnpm").read_text().replace('"numFailedTests":0', '"numFailedTests":0,"numFailedTestSuites":1'))
v = fv.run_vitest(tree, feat_v, dict(env, STUB_EXIT="1"), logs)
check("run_vitest: a failed suite without failed cases does not explain the exit", [c.verdict for c in v] == [fv.FAIL])
v = fv.run_vitest(tree, feat_v, dict(env, STUB_EXIT="0"), logs)
check("run_vitest: clean exit keeps the pass", [c.verdict for c in v] == [fv.PASS])
check("version: untagged branch uses the describe form the CLI gates accept", fv.resolve_version(feat, "", feat[:9]) == "0.0.0-0-g%s" % feat[:9])
subprocess.run(["git", "-C", str(repo), "tag", "v0.11.0", old], check=True)
v = fv.resolve_version(feat, "", feat[:9])
check("version: commit past a tag reports git describe (%s)" % v, v.startswith("v0.11.0-1-g"))
sys.exit(1 if failed else 0)
PY
# stack-remote.sh: the candidate's migrations are applied to multica_gotest, and
# gotest_db=ok is written only when that worked. docker is a recording stub.
STACK="$HERE/fork-verify/stack-remote.sh"
stack_case() { # <name> <docker-run-rc> <psql-version> -> prints stack.env; docker args in $T/<name>.docker
  local name="$1" rc="$2" ver="$3" d="$T/stack-$1"
  mkdir -p "$d"
  RC="$rc" VER="$ver" LOG="$T/$name.docker" D="$d" bash -c '
    source "$1" up "$D" abc
    docker() {
      printf "%s\n" "$*" >>"$LOG"
      case "$1" in
        run) return "$RC" ;;
        exec) printf "%s\n" "$VER" ;;
      esac
    }
    migrate_gotest_db secretpw
    write_stack_env 1 2 3 100 100 120
    echo "state=$gotest_db"
  ' _ "$STACK" >"$T/$name.out" 2>"$T/$name.err"
  cat "$d/stack.env" "$T/$name.out" 2>/dev/null
}
ok_out="$(stack_case ok 0 20261120000000)"
if printf '%s' "$ok_out" | grep -qx 'gotest_db=ok' && printf '%s' "$ok_out" | grep -qx 'gotest_migrations=20261120000000'; then echo "ok   stack: migrated test DB -> gotest_db=ok with its version"; else echo "FAIL stack: migrated test DB: $ok_out"; fail=1; fi
run_line="$(grep '^run ' "$T/ok.docker" | head -1)"
case "$run_line" in
  *"--network fv-abc-net"*"--entrypoint ./migrate"*"/multica_gotest?"*"fv-abc-backend:candidate up") echo "ok   stack: migrate runs in the candidate image on the stack network against multica_gotest";;
  *) echo "FAIL stack: migrate command: $run_line"; fail=1;;
esac
bad_out="$(stack_case bad 1 20261120000000)"
if printf '%s' "$bad_out" | grep -qx 'gotest_db=failed' && ! printf '%s' "$bad_out" | grep -qx 'gotest_db=ok'; then echo "ok   stack: failed migrate -> gotest_db=failed"; else echo "FAIL stack: failed migrate: $bad_out"; fail=1; fi
empty_out="$(stack_case empty 0 '')"
if printf '%s' "$empty_out" | grep -qx 'gotest_db=failed'; then echo "ok   stack: migrate exits 0 but nothing recorded -> gotest_db=failed"; else echo "FAIL stack: empty schema_migrations: $empty_out"; fail=1; fi
if grep -q 'secretpw' "$T/bad.err" "$T/bad.out" 2>/dev/null; then echo "FAIL stack: password leaked into output"; fail=1; else echo "ok   stack: password stays out of output"; fi
direct="$(bash "$STACK" bogus x y 2>&1)"
if [ "$direct" = "unknown command bogus" ]; then echo "ok   stack: running it still dispatches the command"; else echo "FAIL stack: direct run does not dispatch"; fail=1; fi
[ "$fail" = 0 ] && echo "fork-verify.test: all passed" || { echo "fork-verify.test: FAILED"; exit 1; }

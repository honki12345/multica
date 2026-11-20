#!/usr/bin/env python3
"""fork-verify: run every fork feature in fork/features.yml against a candidate ref.

Entry point is scripts/hoon/fork-verify.sh (FORK.md "Fork verification").

Layers, each recorded per feature as pass / fail / unverified / n/a:
  test      registry `tests`: Go tests (go test -run, this Mac, -p 2) and vitest
            files/cases (this Mac, --maxWorkers=2) on an export of the candidate.
  scenario  registry `scenarios` of server/cli/daemon features, run for real
            against a candidate stack: the candidate's images on the remote
            Docker host with a restored production backup, a test Hermes
            gateway and a test daemon on this Mac with their own HOME.
  screen    registry `scenarios` of web-ui features: production and candidate
            web in the same headless browser, same data (production GET
            responses replayed), production read only; prod | cand | diff.

A feature whose origin commits are not in the candidate is n/a. Exit 0 when
nothing failed, 1 when anything failed, 2 when the run could not start.
"""
import argparse
import dataclasses
import datetime
import glob
import hashlib
import json
import os
import re
import secrets
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

import yaml
from PIL import Image, ImageChops, ImageDraw

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]

# DB-backed Go tests skip or fail against this instead of reaching a local default Postgres.
NO_DB_URL = "postgres://fork-verify-no-db.invalid:1/none?sslmode=disable&connect_timeout=2"

PASS, FAIL, UNVERIFIED, NA = "pass", "fail", "unverified", "n/a"
VERDICT_KO = {PASS: "통과", FAIL: "실패", UNVERIFIED: "확인 불가", NA: "해당 없음"}

# Bottom bar chat fixture: more chats than fit at 1440 or 900, so the strip has
# to scroll and an upstream "+N" menu would show.
FIXTURE_CHATS = 12

# Routes a changed path most likely shows up on (screen input from
# upstream-triage --json `screen_inputs`). First match wins.
ROUTE_MAP = [
    ("packages/views/chat/", "/{slug}/chat"),
    ("packages/core/chat/", "/{slug}/chat"),
    ("packages/views/inbox/", "/{slug}/inbox"),
    ("packages/core/inbox/", "/{slug}/inbox"),
    ("packages/views/projects/", "/{slug}/projects"),
    ("packages/views/agents/", "/{slug}/agents"),
    ("packages/views/autopilots/", "/{slug}/autopilots"),
    ("packages/views/issues/", "/{slug}/issues"),
    ("packages/views/layout/", "/{slug}/issues"),
    ("packages/ui/", "/{slug}/issues"),
]


@dataclasses.dataclass
class Check:
    feature: str
    layer: str
    name: str
    verdict: str
    detail: str
    evidence: list = dataclasses.field(default_factory=list)


def log(msg):
    print("[fork-verify %s] %s" % (time.strftime("%H:%M:%S"), msg), file=sys.stderr, flush=True)


def run(cmd, **kw):
    kw.setdefault("capture_output", True)
    kw.setdefault("text", True)
    return subprocess.run(cmd, **kw)


def git(*args, check=True):
    p = run(["git", "-C", str(REPO), *args])
    if check and p.returncode != 0:
        raise RuntimeError("git %s: %s" % (" ".join(args), p.stderr.strip()))
    return p


def feature_verdict(checks):
    vs = {c.verdict for c in checks}
    if FAIL in vs:
        return FAIL
    if UNVERIFIED in vs:
        return UNVERIFIED
    if vs == {NA} or not vs:
        return NA
    return PASS


def exit_code(checks):
    return 1 if any(c.verdict == FAIL for c in checks) else 0


def slugify_ref(ref):
    return re.sub(r"[^A-Za-z0-9._-]+", "-", ref).strip("-") or "ref"


# ---------- registry ----------

def load_registry(ref, path="fork/features.yml"):
    p = git("show", "%s:%s" % (ref, path))
    return yaml.safe_load(p.stdout)


def feature_in_candidate(feature, sha):
    """True when every origin commit is an ancestor of the candidate."""
    commits = (feature.get("origin") or {}).get("commits") or []
    for c in commits:
        if git("merge-base", "--is-ancestor", str(c), sha, check=False).returncode != 0:
            return False
    return True


# ---------- unit tests ----------

GO_RESULT = re.compile(r"^\s*--- (PASS|FAIL|SKIP): (\S+) \(")


def parse_go_test_output(text, names):
    """Map test name -> PASS / FAIL / SKIP / None (not run)."""
    seen = {}
    for line in text.splitlines():
        m = GO_RESULT.match(line)
        if m and "/" not in m.group(2):
            seen[m.group(2)] = m.group(1)
    return {n: seen.get(n) for n in names}


def parse_vitest_json(data, tree, rel_file, case):
    """Return (verdict, detail) for one registry vitest entry."""
    files = [r for r in data.get("testResults", []) if os.path.normpath(r.get("name", "")).endswith(os.path.normpath(rel_file))]
    if not files:
        return FAIL, "결과 없음(파일이 실행되지 않음)"
    results = [a for f in files for a in f.get("assertionResults", [])]
    # A file that failed with no failing case (load error, failing hook) fails
    # every entry in it; a failing case only fails the entries it covers.
    broken = [f for f in files if f.get("status") != "passed"
              and not any(a.get("status") == "failed" for a in f.get("assertionResults", []))]
    if broken:
        return FAIL, "파일 상태 %s: %s" % (broken[0].get("status"), (broken[0].get("message") or "")[:200])
    if case:
        hits = [a for a in results if a.get("title") == case or a.get("fullName") == case or a.get("fullName", "").endswith(" " + case)]
        if not hits:
            return FAIL, "사례 없음: %s" % case
        bad = [a for a in hits if a.get("status") != "passed"]
        return (FAIL, "사례 %s: %s" % (case, bad[0].get("status"))) if bad else (PASS, "사례 통과")
    bad = [a for a in results if a.get("status") not in ("passed", "skipped", "pending", "todo")]
    if bad:
        return FAIL, "%d/%d 실패: %s" % (len(bad), len(results), bad[0].get("fullName", ""))
    passed = sum(1 for a in results if a.get("status") == "passed")
    if not passed:
        return FAIL, "통과한 사례 없음(%d개 모두 건너뜀)" % len(results)
    return PASS, "%d개 통과" % passed


def run_go_tests(tree, features, env, logdir, real_agent, hermes_env):
    checks = []
    groups = {}
    for f in features:
        for t in f.get("tests") or []:
            if "go" not in t:
                continue
            key = (t["go"], t.get("tags", ""), bool(t.get("real_agent")))
            groups.setdefault(key, []).append((f["id"], t["name"]))
    for (pkg, tags, real), items in sorted(groups.items()):
        names = sorted({n for _, n in items})
        if real and not real_agent:
            for fid, n in items:
                checks.append(Check(fid, "test", "go %s %s" % (pkg, n), UNVERIFIED,
                                    "실제 에이전트 시험: --real-agent 없이 돌리지 않음(저장소 규칙)"))
            continue
        rel = os.path.relpath(pkg, "server")
        cmd = ["go", "test", "-count=1", "-p", "2", "-v", "-run", "^(%s)$" % "|".join(names), "./" + rel]
        if tags:
            cmd[2:2] = ["-tags", tags]
        e = dict(env)
        if real:
            # HOME becomes the test home; keep the shared Go caches.
            vals = run(["go", "env", "GOPATH", "GOMODCACHE", "GOCACHE"]).stdout.split("\n")
            e.update(hermes_env)
            e.update(zip(("GOPATH", "GOMODCACHE", "GOCACHE"), vals))
            e["MULTICA_RUN_REAL_AGENT_SMOKE"] = "1"
        log("go test %s (%d tests)" % (pkg, len(names)))
        t0 = time.time()
        p = run(cmd, cwd=str(tree / "server"), env=e, timeout=1500)
        lf = logdir / ("go-%s.log" % slugify_ref(pkg + ("-" + tags if tags else "")))
        lf.write_text(" ".join(cmd) + "\n\n" + p.stdout + p.stderr)
        res = parse_go_test_output(p.stdout, names)
        for fid, n in items:
            r = res.get(n)
            if r == "PASS":
                checks.append(Check(fid, "test", "go %s %s" % (pkg, n), PASS, "통과 (%.0fs)" % (time.time() - t0), [str(lf)]))
            elif r == "FAIL":
                checks.append(Check(fid, "test", "go %s %s" % (pkg, n), FAIL, "실패", [str(lf)]))
            elif r == "SKIP":
                checks.append(Check(fid, "test", "go %s %s" % (pkg, n), UNVERIFIED, "건너뜀(SKIP)", [str(lf)]))
            elif p.returncode != 0:
                checks.append(Check(fid, "test", "go %s %s" % (pkg, n), FAIL, "빌드 또는 실행 실패 (exit %d)" % p.returncode, [str(lf)]))
            else:
                checks.append(Check(fid, "test", "go %s %s" % (pkg, n), UNVERIFIED, "실행되지 않음(DB 없음으로 건너뛴 패키지일 수 있음)", [str(lf)]))
    return checks


def run_vitest(tree, features, env, logdir):
    checks = []
    entries = [(f["id"], t["vitest"], t.get("name")) for f in features for t in f.get("tests") or [] if "vitest" in t]
    if not entries:
        return checks
    log("pnpm install (candidate tree)")
    p = run(["pnpm", "install", "--frozen-lockfile", "--prefer-offline"], cwd=str(tree), env=env, timeout=900)
    (logdir / "pnpm-install.log").write_text(p.stdout + p.stderr)
    if p.returncode != 0:
        return [Check(fid, "test", "vitest %s" % f, FAIL, "pnpm install 실패", [str(logdir / "pnpm-install.log")]) for fid, f, _ in entries]
    byws = {}
    for fid, f, case in entries:
        ws = "/".join(f.split("/")[:2])
        byws.setdefault(ws, []).append((fid, f, case))
    for ws, items in sorted(byws.items()):
        files = sorted({os.path.relpath(f, ws) for _, f, _ in items})
        out = logdir / ("vitest-%s.json" % slugify_ref(ws))
        cmd = ["pnpm", "exec", "vitest", "run", *files, "--reporter=json", "--outputFile=%s" % out, "--maxWorkers=2"]
        log("vitest %s (%d files)" % (ws, len(files)))
        p = run(cmd, cwd=str(tree / ws), env=env, timeout=1200)
        (logdir / ("vitest-%s.log" % slugify_ref(ws))).write_text(" ".join(cmd) + "\n\n" + p.stdout[-20000:] + p.stderr[-20000:])
        try:
            data = json.loads(out.read_text())
        except (OSError, ValueError):
            data = {}
        # A non-zero exit with no failing case or file (unhandled error, no JSON)
        # fails everything in the run; otherwise each entry stands on its own.
        explained = data.get("numFailedTests", 0) or data.get("numFailedTestSuites", 0)
        for fid, f, case in items:
            v, d = parse_vitest_json(data, tree, f, case)
            if v == PASS and p.returncode != 0 and not explained:
                v, d = FAIL, "vitest exit %d (처리되지 않은 오류 등): %s" % (p.returncode, d)
            checks.append(Check(fid, "test", "vitest %s%s" % (f, " · " + case if case else ""), v, d, [str(out)]))
    return checks


# ---------- candidate stack ----------

class Stack:
    def __init__(self, args, sha, short, version, name, logdir):
        self.a, self.sha, self.short, self.version, self.name, self.logdir = args, sha, short, version, name, logdir
        self.host = args.host
        self.rdir = "fork-verify/%s" % name
        self.db_port, self.api_port, self.web_port = args.port_base + 2, args.port_base + 1, args.port_base
        self.tunnel = None
        self.info = {}
        self.pat = None
        self.user_id = self.ws_id = None
        self.up_ok = False
        self.remote_started = False

    @property
    def api(self):
        return "http://127.0.0.1:%d" % self.api_port

    @property
    def web(self):
        return "http://127.0.0.1:%d" % self.web_port

    def ssh(self, cmd, **kw):
        return run(["ssh", "-o", "BatchMode=yes", self.host, cmd], **kw)

    def psql(self, sql, db="multica"):
        p = run(["ssh", "-o", "BatchMode=yes", self.host, "docker exec -i fv-%s-pg psql -U multica -d %s -v ON_ERROR_STOP=1 -At -f -" % (self.name, db)],
                input=sql, timeout=60)
        if p.returncode != 0:
            raise RuntimeError("psql: %s" % p.stderr.strip()[-300:])
        return p.stdout.strip()

    def ports_free(self):
        busy = []
        for port in (self.db_port, self.api_port, self.web_port):
            with socket.socket() as s:
                if s.connect_ex(("127.0.0.1", port)) == 0:
                    busy.append("local:%d" % port)
        p = self.ssh("ss -Hltn")
        for port in (self.db_port, self.api_port, self.web_port):
            if re.search(r":%d\s" % port, p.stdout + " "):
                busy.append("%s:%d" % (self.host, port))
        return busy

    def up(self, backup):
        t0 = time.time()
        tgz = Path(tempfile.mkdtemp(prefix="fork-verify-src-")) / "src.tgz"
        git("archive", "--format=tar.gz", "-o", str(tgz), self.sha)
        self.remote_started = True
        self.ssh("mkdir -p %s && chmod 700 %s" % (self.rdir, self.rdir), check=True)
        for local, remote in ((HERE / "stack-remote.sh", "stack-remote.sh"), (tgz, "src.tgz"), (Path(backup), "backup.dump")):
            run(["scp", "-q", "-o", "BatchMode=yes", str(local), "%s:%s/%s" % (self.host, self.rdir, remote)], check=True)
        shutil.rmtree(tgz.parent, ignore_errors=True)
        log("stack up on %s (build + restore + boot)" % self.host)
        p = self.ssh("bash %s/stack-remote.sh up ~/%s %s %d %d %d %s %s" % (self.rdir, self.rdir, self.name, self.db_port, self.api_port,
                                                                          self.web_port, self.version, self.short), timeout=2400)
        (self.logdir / "stack-up.log").write_text(p.stdout + p.stderr)
        for line in p.stdout.splitlines():
            if "=" in line and not line.startswith("stats "):
                k, v = line.split("=", 1)
                self.info[k] = v
        self.info["stats"] = [l[6:] for l in p.stdout.splitlines() if l.startswith("stats ")]
        self.info["upload_secs"] = "%.0f" % (time.time() - t0 - sum(int(self.info.get(k, 0)) for k in ("build_secs", "restore_secs", "boot_secs")))
        if p.returncode != 0:
            raise RuntimeError("stack up failed (see %s)" % (self.logdir / "stack-up.log"))
        self.tunnel = subprocess.Popen(
            ["ssh", "-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15",
             "-L", "%d:127.0.0.1:%d" % (self.api_port, self.api_port), "-L", "%d:127.0.0.1:%d" % (self.web_port, self.web_port),
             "-L", "%d:127.0.0.1:%d" % (self.db_port, self.db_port), self.host],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(30):
            if http_status(self.api + "/readyz") == 200 and http_status(self.web + "/login") == 200:
                break
            time.sleep(1)
        else:
            raise RuntimeError("tunnel to the candidate stack did not come up")
        self.up_ok = True

    def seed(self):
        self.pat = "mul_" + secrets.token_hex(20)
        sql = (HERE / "seed.sql").read_text()
        p = run(["ssh", "-o", "BatchMode=yes", self.host,
                 "docker exec -i fv-%s-pg psql -U multica -d multica -At -v email=fork-verify@example.invalid -v ws_slug=fork-verify "
                 "-v token_hash=%s -v token_prefix=%s -f -" % (self.name, hashlib.sha256(self.pat.encode()).hexdigest(), self.pat[:12])],
                input=sql, timeout=60)
        m = re.search(r"user_id=([0-9a-f-]{36})\|workspace_id=([0-9a-f-]{36})", p.stdout)
        if p.returncode != 0 or not m:
            raise RuntimeError("seeding the test identity failed: %s" % p.stderr.strip()[-300:])
        self.user_id, self.ws_id = m.group(1), m.group(2)
        api_json(self.api, "/api/workspaces/%s" % self.ws_id, self.pat, self.ws_id, method="PATCH",
                 body={"repos": [{"url": self.a.repo_url}]})

    def gotest_db_url(self):
        pw = self.ssh("cat %s/pgpw" % self.rdir).stdout.strip()
        if not pw or self.info.get("gotest_db") != "ok":
            return ""
        return "postgres://multica:%s@127.0.0.1:%d/multica_gotest?sslmode=disable" % (pw, self.db_port)

    def remote_stats(self):
        p = self.ssh("docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' fv-%s-pg fv-%s-backend fv-%s-web; uptime"
                     % (self.name, self.name, self.name))
        return p.stdout.strip().splitlines()

    def down(self):
        if self.tunnel:
            self.tunnel.terminate()
            try:
                self.tunnel.wait(10)
            except subprocess.TimeoutExpired:
                self.tunnel.kill()
        # Stop a remote `up` still building (local ssh may have died first), then
        # remove by name; stack-remote.sh may already be gone with its directory.
        p = self.ssh("for pid in $(pgrep -f '^bash [^ ]*stack-remote.sh up [^ ]*/{d} {n} '); do kill $pid; done; sleep 2; "
                     "docker rm -f -v fv-{n}-web fv-{n}-backend fv-{n}-pg; docker volume rm -f fv-{n}-pgdata fv-{n}-uploads; "
                     "docker network rm fv-{n}-net; docker image rm -f fv-{n}-backend:candidate fv-{n}-web:candidate; "
                     "rm -rf ~/{d}; true".format(n=self.name, d=self.rdir), timeout=300)
        left = self.ssh("docker ps -aq --filter name=fv-{n}- | wc -l; docker volume ls -q --filter name=fv-{n}- | wc -l; "
                        "docker images -q 'fv-{n}-*' | wc -l".format(n=self.name))
        self.info["left_after_down"] = " ".join(left.stdout.split())
        (self.logdir / "stack-down.log").write_text(p.stdout + p.stderr)


def http_status(url):
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except OSError:
        return 0


def describe_error(e):
    if isinstance(e, urllib.error.HTTPError):
        try:
            body = e.read().decode(errors="replace")[:300]
        except OSError:
            body = ""
        return "HTTP %d %s %s" % (e.code, e.url, body)
    return str(e)


def api_json(base, path, token, ws_id, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method, headers={
        "Authorization": "Bearer " + token, "X-Workspace-ID": ws_id, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read()
    return json.loads(raw) if raw else None


# ---------- resident runtime (test gateway + test daemon) ----------

# Run messages keep only the first ~480 chars of each tool output, so the JSON
# commands grep the fields the judge reads.
RESIDENT_ISSUE = """fork-verify resident scenario. Run each command below from your task working directory, one per terminal call, in this order:

1. `multica issue get {issue} --output json | grep -E '"(identifier|status)"'`
2. `multica daemon status --output json | grep -E '"(status|cli_version)"'`
3. `multica repo checkout {repo}`
4. `multica environment list`
5. `ls -a ..`

Then write ./reply.md with one line per command saying whether it succeeded, post it with `multica issue comment add {issue} --content-file ./reply.md`, and stop. Do not change the issue status and do not run anything else.
"""

STEER_ISSUE = """fork-verify steer scenario. Run `sleep 60` in the foreground as one terminal call and wait for it to finish. While it runs, the requester will send you a code word as an additional message. After the sleep finishes, write ./reply.md containing exactly `CODE=<code word>` (or `CODE=NONE` if no code word arrived), post it with `multica issue comment add {issue} --content-file ./reply.md`, and stop. Do not run any other command.
"""


class Resident:
    def __init__(self, args, stack, version, logdir, cli_bin):
        self.a, self.stack, self.version, self.logdir, self.cli_bin = args, stack, version, logdir, cli_bin
        self.home = Path(tempfile.mkdtemp(prefix="fork-verify-home-"))
        self.procs = {}
        self.agent_id = None
        self.ready_reason = ""

    def base_env(self):
        e = {"HOME": str(self.home), "USER": os.environ.get("USER", ""), "LOGNAME": os.environ.get("USER", ""),
             "SHELL": "/bin/zsh", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
             "PATH": "%s:%s" % (self.home / "bin", self.a.hermes_path_dirs), "HERMES_HOME": str(self.home / ".hermes"),
             "HERMES_DISABLE_LAZY_INSTALLS": "1"}
        for k in self.a.hermes_env.split(","):
            if k and os.environ.get(k):
                e[k] = os.environ[k]
        return e

    def cli(self, *args, check=False, timeout=120):
        p = run([str(self.cli_bin), "--profile", "fork-verify", *args], cwd=str(self.home),
                env={"HOME": str(self.home), "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp")}, timeout=timeout)
        if check and p.returncode != 0:
            raise RuntimeError("multica %s: %s" % (" ".join(args[:3]), p.stderr.strip()[-300:]))
        return p

    def cli_json(self, *args):
        p = self.cli(*args, "--output", "json", check=True)
        return json.loads(p.stdout)

    def prepare_hermes_home(self):
        """Test HERMES_HOME: own config (model via the local proxy), shared dependency install only."""
        hh = self.home / ".hermes"
        if (hh / "config.yaml").exists():
            return hh
        hh.mkdir(parents=True, exist_ok=True)
        (self.home / "bin").mkdir(exist_ok=True)
        os.symlink(self.cli_bin, self.home / "bin" / "multica")
        installs = Path(self.a.hermes_installs).expanduser()
        if installs.exists():
            os.symlink(installs, hh / "installs")
        cfg = (HERE / "hermes-config.yaml").read_text().replace("__MODEL__", self.a.agent_model)
        (hh / "config.yaml").write_text(cfg)
        return hh

    def start(self):
        missing = [k for k in self.a.hermes_env.split(",") if k and not os.environ.get(k)]
        if not shutil.which("hermes", path=self.a.hermes_path_dirs):
            self.ready_reason = "hermes가 PATH(%s)에 없음" % self.a.hermes_path_dirs
            return False
        if missing:
            self.ready_reason = "Hermes 모델 키 환경변수 없음: %s" % ",".join(missing)
            return False
        hh = self.prepare_hermes_home()
        prof = self.home / ".multica" / "profiles" / "fork-verify"
        prof.mkdir(parents=True)
        fd = os.open(prof / "config.json", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.write(fd, json.dumps({"server_url": self.stack.api, "app_url": self.stack.web, "workspace_id": self.stack.ws_id,
                                 "token": self.stack.pat, "device_name": "fork-verify"}).encode())
        os.close(fd)
        os.chmod(self.home, 0o700)
        owner = dict(self.base_env(), MULTICA_RESIDENT_OWNER="1", MULTICA_CLI_PATH=str(self.cli_bin), MULTICA_SERVER_URL=self.stack.api)
        self.procs["owner"] = subprocess.Popen(["hermes", "gateway", "run", "--external-supervisor"], cwd=str(self.home), env=owner,
                                               stdout=open(self.logdir / "hermes-owner.log", "w"), stderr=subprocess.STDOUT)
        for _ in range(90):
            # A long HERMES_HOME puts the socket in a temp dir and leaves a
            # gateway.sock.path pointer instead (unix socket path length).
            if (hh / "gateway.sock").exists() or (hh / "gateway.sock.path").exists():
                break
            if self.procs["owner"].poll() is not None:
                self.ready_reason = "시험 Hermes gateway가 바로 종료됨(%s)" % (self.logdir / "hermes-owner.log")
                return False
            time.sleep(1)
        else:
            self.ready_reason = "시험 Hermes gateway가 90초 안에 제어 소켓을 만들지 않음"
            return False
        port = 19514 + 1 + sum(b"fork-verify") % 1000
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", port)) == 0:
                self.ready_reason = "시험 데몬 포트 %d가 이미 쓰이는 중" % port
                return False
        denv = dict(self.base_env(), MULTICA_HERMES_RESIDENT_GATEWAY="1", MULTICA_DAEMON_AUTO_UPDATE="false",
                    MULTICA_DAEMON_AUTO_RELOAD="false", MULTICA_WORKSPACES_ROOT=str(self.home / "workspaces"), MULTICA_GC_ENABLED="false")
        self.procs["daemon"] = subprocess.Popen([str(self.cli_bin), "--profile", "fork-verify", "daemon", "start", "--foreground",
                                                 "--device-name", "fork-verify"], cwd=str(self.home), env=denv,
                                                stdout=open(self.logdir / "daemon.log", "w"), stderr=subprocess.STDOUT)
        rt = None
        for _ in range(60):
            p = self.cli("runtime", "list", "--output", "json")
            if p.returncode == 0:
                rts = [r for r in json.loads(p.stdout) if r.get("provider") == "hermes" and r.get("status") == "online"]
                if rts:
                    rt = rts[0]["id"]
                    break
            time.sleep(2)
        if not rt:
            self.ready_reason = "시험 데몬의 Hermes 런타임이 online이 되지 않음"
            return False
        agent = self.cli_json("agent", "create", "--name", "fv-resident", "--runtime-id", rt, "--model", self.a.agent_model,
                              "--max-concurrent-tasks", "3", "--instructions",
                              "You are the fork-verify test agent. Follow the issue exactly and run only the commands it names.")
        self.agent_id = agent["id"]
        return True

    def create_issue(self, title, body):
        fname = "issue-%s.md" % secrets.token_hex(4)
        (self.home / fname).write_text(body)
        issue = self.cli_json("issue", "create", "--title", title, "--description-file", "./" + fname, "--status", "backlog")
        body = body.replace("{issue}", issue["id"]).replace("{repo}", self.a.repo_url)
        (self.home / fname).write_text(body)
        self.cli("issue", "update", issue["id"], "--description-file", "./" + fname, check=True)
        self.cli("issue", "assign", issue["id"], "--to-id", self.agent_id, check=True)
        self.cli("issue", "status", issue["id"], "todo", check=True)
        return issue

    def runs(self, issue_id, active=False):
        args = ["issue", "runs", issue_id] + (["--active"] if active else [])
        p = self.cli(*args, "--output", "json")
        return json.loads(p.stdout) if p.returncode == 0 and p.stdout.strip() else []

    def wait_done(self, issue_id, limit):
        end = time.time() + limit
        while time.time() < end:
            rs = self.runs(issue_id)
            if rs and all(r["status"] in ("completed", "failed", "cancelled") for r in rs):
                return rs
            time.sleep(5)
        return None

    def messages(self, run_id):
        p = self.cli("issue", "run-messages", run_id, "--output", "json", timeout=60)
        return json.loads(p.stdout) if p.returncode == 0 and p.stdout.strip() else []

    def comments(self, issue_id):
        return self.cli_json("issue", "comment", "list", issue_id)

    def stop(self):
        for name in ("daemon", "owner"):
            p = self.procs.get(name)
            if not p or p.poll() is not None:
                continue
            p.send_signal(signal.SIGTERM)
            try:
                p.wait(30)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait(10)

    def cleanup(self):
        shutil.rmtree(self.home, ignore_errors=True)


def tool_outputs(messages):
    return [str(m.get("output") or "") for m in messages if m.get("output")]


def judge_resident(outputs, version, ident, root_after, comments, agent_id):
    """Checks per feature for the resident issue run. Pure: inputs are what the run produced."""
    out = []
    joined = "\n".join(outputs)
    got_issue = any(re.search(r'"identifier":\s*"%s"' % re.escape(ident), o) for o in outputs)
    by_agent = [c for c in comments if c.get("author_type") == "agent" and c.get("author_id") == agent_id]
    ls = [o for o in outputs if ".task_lock" in o or ".task_owner" in o]
    ctx_during = any(".multica_resident_task.json" in o for o in ls)
    ctx_after = (root_after / ".multica_resident_task.json").exists() if root_after else None
    ok = got_issue and by_agent and ctx_during and ctx_after is False
    out.append(("resident-hermes-gateway", "resident task runs with its own identity", PASS if ok else FAIL,
                "issue get=%s, 에이전트 작성 댓글=%d, 실행 중 컨텍스트 파일=%s, 실행 후 남음=%s" % (
                    "성공" if got_issue else "실패", len(by_agent), "있음" if ctx_during else "없음",
                    {None: "확인 못 함", True: "남음", False: "지워짐"}[ctx_after])))
    overlay_during = any("hermes-home" in o for o in ls)
    overlay_after = (root_after / "hermes-home").exists() if root_after else None
    ok = bool(ls) and not overlay_during and overlay_after is False
    out.append(("resident-no-hermes-home-overlay", "resident task has no hermes-home overlay", PASS if ok else FAIL,
                "`ls -a ..` 출력 %s, hermes-home 실행 중=%s, 실행 후=%s" % (
                    "있음" if ls else "없음", "있음" if overlay_during else "없음",
                    {None: "확인 못 함", True: "있음", False: "없음"}[overlay_after])))
    checkout = "Checked out " in joined and "agent/" in joined
    port_err = "MULTICA_DAEMON_PORT" in joined and ("not set" in joined or "requires" in joined)
    env_ok = any(("No environments" in o or re.search(r"^\s*NAME\s", o, re.M)) for o in outputs) and not port_err
    out.append(("resident-daemon-local-commands", "repo checkout from a resident tool shell", PASS if (checkout and env_ok) else FAIL,
                "repo checkout=%s, environment list=%s%s" % ("성공" if checkout else "실패", "성공" if env_ok else "실패",
                                                             ", MULTICA_DAEMON_PORT 오류 있음" if port_err else "")))
    statuses = []
    for o in outputs:
        st = re.findall(r'"status":\s*"([a-z_]+)"', o)
        ver = re.findall(r'"cli_version":\s*"([^"]+)"', o)
        if ver:
            statuses.append((st[-1] if st else "?", ver[-1]))
    pairs = statuses
    running = [p for p in pairs if p[0] == "running" and p[1] == version]
    ok = bool(pairs) and len(running) == len(pairs)
    out.append(("resident-daemon-status", "daemon status from a resident tool shell", PASS if ok else FAIL,
                "%d번 중 running+%s %d번 (%s)" % (len(pairs), version, len(running), ", ".join("%s/%s" % p for p in pairs) or "출력 없음")))
    return out


def run_scenarios(res, stack, features, version, logdir):
    """Server/cli/daemon scenarios. Returns checks; unknown scenarios stay unverified."""
    checks = []
    want = {f["id"] for f in features}
    known = {"resident-hermes-gateway", "resident-no-hermes-home-overlay", "resident-daemon-local-commands", "resident-daemon-status",
             "hermes-steer-supplement", "resident-quick-create-context", "inbox-cli-manage", "inbox-list-filters"}
    for f in features:
        if f["id"] not in known:
            for s in f.get("scenarios") or []:
                checks.append(Check(f["id"], "scenario", s["name"], UNVERIFIED,
                                    "fork-verify에 이 시나리오 실행기가 없음(kind: %s)" % f.get("kind")))
    need_resident = want & {"resident-hermes-gateway", "resident-no-hermes-home-overlay", "resident-daemon-local-commands",
                            "resident-daemon-status", "hermes-steer-supplement", "resident-quick-create-context"}
    started = []
    if need_resident:
        log("resident runtime: test Hermes gateway + test daemon")
        if not res.start():
            for fid in sorted(need_resident):
                checks.append(Check(fid, "scenario", "resident", UNVERIFIED, "시험 런타임을 띄우지 못함: " + res.ready_reason))
            need_resident = set()
    t0 = time.time()
    if need_resident & {"resident-hermes-gateway", "resident-no-hermes-home-overlay", "resident-daemon-local-commands", "resident-daemon-status"}:
        started.append(("resident", res.create_issue("[fork-verify] resident path", RESIDENT_ISSUE)))
    if "hermes-steer-supplement" in need_resident:
        started.append(("steer", res.create_issue("[fork-verify] steer", STEER_ISSUE)))
    qc_task = None
    if "resident-quick-create-context" in need_resident:
        qc = api_json(stack.api, "/api/issues/quick-create", stack.pat, stack.ws_id, method="POST",
                      body={"agent_id": res.agent_id, "prompt": "fork-verify quick create probe: create an issue titled 'fv quick create probe' with a one-line description."})
        qc_task = (qc or {}).get("task_id")
    issues = dict(started)

    if "steer" in issues:
        iid = issues["steer"]["id"]
        run_id = None
        steer_out = ""
        end = time.time() + 240
        while time.time() < end and not run_id:
            run_id = next((r["id"] for r in res.runs(iid, active=True) if r["status"] == "running" and r.get("can_supplement")), None)
            if not run_id:
                time.sleep(3)
        if run_id:
            time.sleep(10)
            (res.home / "steer.md").write_text("The code word is %s.\n" % "PINEAPPLE")
            sp = res.cli("issue", "comment", "add", iid, "--content-file", "./steer.md", "--steer", run_id, "--output", "table")
            steer_out = sp.stderr.strip()
        else:
            steer_out = "run never became steerable (can_supplement)"
        (logdir / "steer-comment.log").write_text(steer_out)

    for key, issue in started:
        rs = res.wait_done(issue["id"], 480)
        (logdir / ("run-%s.json" % key)).write_text(json.dumps(rs, indent=1))
        if rs is None:
            fids = ["hermes-steer-supplement"] if key == "steer" else sorted(need_resident - {"hermes-steer-supplement", "resident-quick-create-context"})
            for fid in fids:
                checks.append(Check(fid, "scenario", key, FAIL, "8분 안에 실행이 끝나지 않음"))
            continue
        msgs = res.messages(rs[-1]["id"])
        (logdir / ("run-%s-messages.json" % key)).write_text(json.dumps(msgs, indent=1, ensure_ascii=False))
        comments = res.comments(issue["id"])
        if key == "resident":
            rel = rs[-1].get("relative_work_dir")
            root = res.home / "workspaces" / Path(rel).parent if rel else None
            root = root if root and root.is_dir() else None
            for fid, name, v, d in judge_resident(tool_outputs(msgs), version, issue["identifier"], root, comments, res.agent_id):
                if fid in need_resident:
                    checks.append(Check(fid, "scenario", name, v, d, [str(logdir / ("run-%s-messages.json" % key))]))
        else:
            delivered = stack.psql("select status from task_supplement where task_id = '%s'" % rs[-1]["id"]) if rs else ""
            code = [c for c in comments if c.get("author_type") == "agent" and "CODE=" in c.get("content", "")]
            got = code[-1]["content"].strip() if code else "(답 없음)"
            ok = len(rs) == 1 and got == "CODE=PINEAPPLE" and delivered.splitlines()[-1:] == ["delivered"]
            checks.append(Check("hermes-steer-supplement", "scenario", "comment steers a running Hermes task", PASS if ok else FAIL,
                                "실행 %d개, 답 `%s`, task_supplement=%s, %s" % (len(rs), got, delivered or "없음", steer_out.splitlines()[-1] if steer_out else ""),
                                [str(logdir / "steer-comment.log"), str(logdir / ("run-%s-messages.json" % key))]))

    if qc_task:
        row = ""
        end = time.time() + 360
        while time.time() < end:
            row = stack.psql("select number, origin_type, assignee_type, assignee_id from issue where origin_id = '%s'" % qc_task)
            if row:
                break
            time.sleep(5)
        parts = row.split("|") if row else []
        ok = len(parts) == 4 and parts[1] == "quick_create" and parts[2] == "agent" and parts[3] == res.agent_id
        checks.append(Check("resident-quick-create-context", "scenario", "quick create through the resident agent", PASS if ok else FAIL,
                            ("이슈 FV-%s: origin_type=%s, origin_id=작업 id, 담당=%s(%s)" % (parts[0], parts[1], parts[2],
                                                                                    "시험 에이전트" if ok else parts[3][:8])) if parts else
                            "6분 안에 quick_create 이슈가 생기지 않음 (API로 Quick Create 요청, 작업 %s)" % qc_task[:8]))
    if need_resident:
        (logdir / "scenario-timing.txt").write_text("resident scenarios: %.0fs\n" % (time.time() - t0))

    if want & {"inbox-cli-manage", "inbox-list-filters"} and stack.pat:
        checks += run_inbox_scenarios(res, want, logdir)
    return checks


def run_inbox_scenarios(res, want, logdir):
    checks = []
    # The scenarios need a member with notifications on several issues, some
    # unread: give the test user three issues of the test workspace, one
    # mention and one status change each, the first two unread.
    res.stack.psql(
        "WITH i AS (SELECT id, number FROM issue WHERE workspace_id = '{ws}' ORDER BY number LIMIT 3) "
        "INSERT INTO inbox_item (workspace_id, recipient_type, recipient_id, type, issue_id, title, read) "
        "SELECT '{ws}', 'member', '{u}', t.type, i.id, 'fork-verify ' || t.type || ' ' || i.number, i.number > 2 "
        "FROM i CROSS JOIN (VALUES ('mentioned'), ('status_changed')) AS t(type)".format(ws=res.stack.ws_id, u=res.stack.user_id))
    if not res.home.joinpath(".multica").exists():
        prof = res.home / ".multica" / "profiles" / "fork-verify"
        prof.mkdir(parents=True)
        fd = os.open(prof / "config.json", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.write(fd, json.dumps({"server_url": res.stack.api, "workspace_id": res.stack.ws_id, "token": res.stack.pat}).encode())
        os.close(fd)

    def count():
        p = res.cli("inbox", "count", "--output", "json")
        try:
            return p.returncode, int(json.loads(p.stdout)["unread"])
        except (ValueError, KeyError, TypeError):
            return p.returncode, None

    lines = []
    if "inbox-cli-manage" in want:
        rc0, before = count()
        cmds = [("inbox", "count"), ("inbox", "list", "--since", "1d"), ("inbox", "list", "--snoozed")]
        rcs = []
        for c in cmds:
            p = res.cli(*c, "--output", "json")
            rcs.append(p.returncode)
            lines.append("$ multica %s → exit %d %s" % (" ".join(c), p.returncode, p.stderr.strip()[-200:]))
        rc1, after = count()
        ok = all(r == 0 for r in rcs) and before is not None and before == after
        checks.append(Check("inbox-cli-manage", "scenario", "Upstream inbox reads through the fork CLI", PASS if ok else FAIL,
                            "명령 3개 exit=%s, 읽지 않음 수 전 %s / 후 %s" % (",".join(map(str, rcs)), before, after)))
    if "inbox-list-filters" in want:
        rc0, before = count()
        rcs, rows = [], {}
        for label, c in [("unread", ("inbox", "list", "--unread")), ("mention", ("inbox", "list", "--unread", "--type", "mention")),
                         ("not-status", ("inbox", "list", "--status", "todo,in_progress", "--not", "status"))]:
            p = res.cli(*c, "--output", "json")
            rcs.append(p.returncode)
            try:
                rows[label] = json.loads(p.stdout)
            except ValueError:
                rows[label] = None
            lines.append("$ multica %s → exit %d, %s행" % (" ".join(c), p.returncode, len(rows[label]) if isinstance(rows[label], list) else "?"))
        bad = res.cli("inbox", "list", "--type", "mentions", "--output", "json")
        lines.append("$ multica inbox list --type mentions → exit %d %s" % (bad.returncode, bad.stderr.strip()[-300:]))
        rc1, after = count()
        bad_ok = bad.returncode != 0 and "mention" in bad.stderr
        unread, mention = rows.get("unread") or [], rows.get("mention") or []
        per_issue = len({r.get("issue_id") for r in unread}) == len(unread)
        only_mentions = bool(mention) and all(r.get("type") == "mentioned" for r in mention)
        ok = all(r == 0 for r in rcs) and bad_ok and before == after and before is not None and per_issue and only_mentions
        checks.append(Check("inbox-list-filters", "scenario", "CLI list matches the filtered web Inbox", PASS if ok else FAIL,
                            "명령 exit=%s; --unread %d행(이슈당 1행 %s); --type mention %d행(모두 멘션 %s); 잘못된 --type 거절 %s; "
                            "읽지 않음 수 전 %s / 후 %s. 웹 인박스와 같은 행인지는 등록된 대조 시험"
                            "(TestInboxFilterParityWithWeb, filter-parity.test.ts)이 맡음" % (
                                ",".join(map(str, rcs)), len(unread), "예" if per_issue else "아니오", len(mention),
                                "예" if only_mentions else "아니오", "예" if bad_ok else "아니오", before, after)))
    (logdir / "inbox-scenarios.log").write_text("\n".join(lines) + "\n")
    return checks


# ---------- screens ----------

def chat_fixture():
    sessions = []
    for i in range(1, FIXTURE_CHATS + 1):
        sessions.append({"id": "00000000-0000-4000-8000-%012d" % i, "workspace_id": "", "agent_id": "00000000-0000-4000-8000-999999999999",
                         "creator_id": "", "title": "fork-verify chat %02d" % i, "status": "active", "has_unread": True,
                         "created_at": "2026-11-%02dT08:00:00Z" % i, "updated_at": "2026-11-%02dT08:00:00Z" % i})
    return {"sessions": sessions, "pending": {"tasks": []}}


def plan_shots(features, slug, screen_input=None):
    """Registry web-ui scenarios (and screen input routes) -> shot specs."""
    shots = []
    for f in features:
        if f.get("kind") != "web-ui":
            continue
        for si, s in enumerate(f.get("scenarios") or []):
            interact = any(re.search(r"\bclick\b", st, re.I) for st in s.get("steps") or [])
            for w in s.get("widths") or []:
                shots.append({"id": "%s-s%d-%d" % (f["id"], si + 1, w), "feature": f["id"], "scenario": s["name"], "scenarioIndex": si,
                              "width": w, "path": s["path"].replace("<workspace-slug>", slug), "selectors": s.get("selectors") or [],
                              "probe": "chat-bar" if f["id"] == "chat-bar-all-chips" else None, "interact": interact and si == 0})
    extra = []
    if screen_input:
        web = {f["id"] for f in features if f.get("kind") == "web-ui"}
        seen = {(s["path"], s["width"]) for s in shots}
        for item in screen_input.get("screen_inputs", []):
            if item.get("feature") not in web:
                continue
            routes = []
            for p in item.get("paths", []):
                r = next((route for prefix, route in ROUTE_MAP if p.startswith(prefix)), None)
                if r and r not in routes:
                    routes.append(r)
            for r in routes:
                path = r.replace("{slug}", slug)
                if (path, 1440) in seen:
                    continue
                seen.add((path, 1440))
                extra.append({"id": "%s-b-%s" % (item["feature"], slugify_ref(path.strip("/").replace("/", "-"))), "feature": item["feature"],
                              "scenario": "B: 주변 화면 %s" % r, "scenarioIndex": -1, "width": 1440, "path": path, "selectors": [],
                              "probe": "chat-bar" if item["feature"] == "chat-bar-all-chips" else None, "interact": False})
    return shots + extra


def diff_ratio(a, b, box=None, tol=24):
    """Share of pixels whose largest channel difference exceeds tol."""
    if a.size != b.size:
        return 1.0
    if box:
        a, b = a.crop(box), b.crop(box)
    mask = _changed_mask(a, b, tol)
    total = mask.width * mask.height
    return mask.histogram()[255] / total if total else 0.0


def _changed_mask(a, b, tol):
    """L image: 255 where any channel differs by more than tol."""
    r, g, bl = ImageChops.difference(a.convert("RGB"), b.convert("RGB")).split()
    biggest = ImageChops.lighter(ImageChops.lighter(r, g), bl)
    return biggest.point([0 if v <= tol else 255 for v in range(256)])


def diff_image(a, b, tol=24):
    mask = _changed_mask(a, b, tol)
    base = b.convert("L").point([40 + v // 4 for v in range(256)]).convert("RGB")
    red = Image.new("RGB", b.size, (230, 30, 30))
    return Image.composite(red, base, mask)


def triptych(prod, cand, out, box=None, scale=1.0):
    a, b = Image.open(prod), Image.open(cand)
    if box:
        a, b = a.crop(box), b.crop(box)
    if b.size != a.size:
        b = b.resize(a.size)
    c = diff_image(a, b)
    if scale != 1.0:
        a, b, c = (im.resize((int(im.width * scale), int(im.height * scale))) for im in (a, b, c))
    head = 22
    W, H = a.width, a.height
    sheet = Image.new("RGB", (W * 3 + 16, H + head), (255, 255, 255))
    draw = ImageDraw.Draw(sheet)
    for i, (im, label) in enumerate(((a, "production"), (b, "candidate"), (c, "diff (red = changed)"))):
        x = i * (W + 8)
        sheet.paste(im, (x, head))
        draw.text((x + 4, 4), label, fill=(0, 0, 0))
    sheet.save(out)


def judge_chat_bar(shot, res, fixture_chips):
    """(verdict, detail) for the bottom chat bar on the candidate (prod in the detail)."""
    c = res.get("cand", {})
    p = res.get("prod", {})
    cp, pp = c.get("probe") or {}, p.get("probe") or {}
    if c.get("error"):
        return FAIL, "후보 화면 오류: %s" % c["error"]
    if c.get("url") != shot["path"] or not c.get("page"):
        return FAIL, "후보가 시나리오 화면을 그리지 못함: 주소 %s, 본문 %s" % (c.get("url"), "있음" if c.get("page") else "없음")
    if shot["scenarioIndex"] == 1 or (shot["scenarioIndex"] == -1 and shot["width"] < 768):
        ok = cp.get("bar", 0) == 0
        return (PASS if ok else FAIL), "768px 미만 채팅 바 %s (운영 %s)" % ("없음" if ok else "있음", "없음" if not pp.get("bar") else "있음")
    if shot["scenarioIndex"] == -1:
        if "/chat" in shot["path"]:
            return (PASS if not cp.get("bar") else FAIL), "채팅 탭에서는 채팅 바가 숨음: 후보 %s" % ("숨음" if not cp.get("bar") else "보임")
        ok = cp.get("chips") == fixture_chips and cp.get("overflowButtons") == 0
        return (PASS if ok else FAIL), "칩 %s/%d, +N 버튼 %s" % (cp.get("chips"), fixture_chips, cp.get("overflowButtons"))
    problems = []
    if not cp.get("bar"):
        problems.append("채팅 바 없음")
    if cp.get("chips") != fixture_chips:
        problems.append("칩 %s/%d" % (cp.get("chips"), fixture_chips))
    if cp.get("overflowButtons"):
        problems.append("+N 버튼 %d개" % cp["overflowButtons"])
    if shot.get("interact"):
        if cp.get("stripScrollable") and not cp.get("wheelScrolled"):
            problems.append("휠로 옆으로 안 밀림")
        if not cp.get("teamStatusKeptWidth", True):
            problems.append("팀 상태 너비 바뀜")
        if not cp.get("windowOpen"):
            problems.append("오른쪽 끝 칩 클릭에 채팅 창 안 열림")
        elif not cp.get("clickedChipInView"):
            problems.append("클릭한 칩이 다 안 보임")
    detail = "후보: 칩 %s/%d, +N %s, 띠 스크롤 %s/휠 %s, 창 %s, 칩 보임 %s · 운영: 칩 %s, +N %s" % (
        cp.get("chips"), fixture_chips, cp.get("overflowButtons"), cp.get("stripScrollable"), cp.get("wheelScrolled"),
        cp.get("windowOpen"), cp.get("clickedChipInView"), pp.get("chips"), pp.get("overflowButtons"))
    return (FAIL if problems else PASS), ("; ".join(problems) + " — " if problems else "") + detail


def run_screens(args, stack, prod, features, out_dir, logdir, screen_input):
    checks = []
    shots = plan_shots(features, prod["slug"], screen_input)
    if not shots:
        return checks, {}
    shot_dir = out_dir / "screens"
    shot_dir.mkdir(parents=True, exist_ok=True)
    session = "fork-verify-%s" % stack.name
    # playwright-cli writes .playwright-cli/ into its cwd; keep it out of the repo.
    pw_cwd = tempfile.mkdtemp(prefix="fv-pw-")
    pw = lambda *a, **kw: run(["playwright-cli", "-s=" + session, *a], cwd=pw_cwd, **kw)
    pw("open", "about:blank", timeout=120)
    fixture = chat_fixture()
    summary = {"prod_blocked": 0, "prod_blocked_sample": [], "cand_passthrough": set(), "replayed": 0}
    try:
        for shot in shots:
            cfg = {"prod": {"name": "prod", "origin": prod["web"], "token": prod["token"], "wsId": prod["ws_id"]},
                   "cand": {"name": "cand", "origin": stack.web, "token": stack.pat, "wsId": stack.ws_id},
                   "fixture": fixture, "mask": args.mask.split(";"), "regionSelector": '[data-slot="app-bottom-bar"]',
                   "height": 900, "locale": "en-US", "timezone": "Asia/Seoul", "now": "2026-11-19T00:00:00Z", "settleMs": 1500,
                   "outDir": str(shot_dir), "shots": [shot]}
            src = (HERE / "screens.js").read_text().replace("__CONFIG__", json.dumps(cfg))
            fd, path = tempfile.mkstemp(prefix="fv-screens-", suffix=".js")
            os.write(fd, src.encode())
            os.close(fd)
            try:
                p = pw("--raw", "run-code", "--filename", path, timeout=600)
            finally:
                os.unlink(path)
            try:
                result = json.loads(json.loads(p.stdout.strip().splitlines()[-1]))
            except (ValueError, IndexError):
                checks.append(Check(shot["feature"], "screen", "%s @%d" % (shot["scenario"], shot["width"]), UNVERIFIED,
                                    "브라우저 실행 실패: %s" % (p.stdout + p.stderr).strip()[-300:]))
                continue
            summary["prod_blocked"] += result["prod"]["blocked"]
            summary["prod_blocked_sample"] = (summary["prod_blocked_sample"] + result["prod"]["blockedSample"])[:6]
            summary["cand_passthrough"].update(result["cand"]["passthrough"])
            summary["replayed"] += result["cand"]["replayed"]
            sres = result["shots"][0]["sides"]
            sid = shot["id"]
            pp, cp = shot_dir / ("%s.prod.png" % sid), shot_dir / ("%s.cand.png" % sid)
            evidence = []
            region_ratio = page_ratio = None
            if pp.exists() and cp.exists():
                a, b = Image.open(pp), Image.open(cp)
                page_ratio = diff_ratio(a, b)
                triptych(pp, cp, shot_dir / ("%s.compare.png" % sid), scale=0.5)
                evidence.append(str(shot_dir / ("%s.compare.png" % sid)))
                reg = sres["cand"].get("region") or sres["prod"].get("region")
                if reg:
                    box = (reg["x"], reg["y"], reg["x"] + reg["w"], reg["y"] + reg["h"])
                    region_ratio = diff_ratio(a, b, box)
                    triptych(pp, cp, shot_dir / ("%s.region.png" % sid), box=box)
                    evidence.insert(0, str(shot_dir / ("%s.region.png" % sid)))
            po, co = shot_dir / ("%s-open.prod.png" % sid), shot_dir / ("%s-open.cand.png" % sid)
            if po.exists() and co.exists():
                triptych(po, co, shot_dir / ("%s-open.compare.png" % sid), scale=0.5)
                evidence.append(str(shot_dir / ("%s-open.compare.png" % sid)))
            missing = [s for s, n in (sres["cand"].get("selectors") or {}).items() if n == 0]
            if shot.get("probe") == "chat-bar":
                v, d = judge_chat_bar(shot, sres, FIXTURE_CHATS)
            else:
                v, d = (FAIL, "후보 화면 오류: %s" % sres["cand"]["error"]) if sres["cand"].get("error") else (PASS, "화면 열림")
            if missing:
                v, d = FAIL, "기대 요소 없음: %s; %s" % (", ".join(missing), d)
            if region_ratio is not None and region_ratio > args.region_threshold:
                v = FAIL
                d = "개조 영역 픽셀 차이 %.2f%% > 기준 %.2f%%; %s" % (region_ratio * 100, args.region_threshold * 100, d)
            d += " · 픽셀 차이: 개조 영역 %s, 전체 %s" % ("-" if region_ratio is None else "%.2f%%" % (region_ratio * 100),
                                                 "-" if page_ratio is None else "%.2f%%" % (page_ratio * 100))
            checks.append(Check(shot["feature"], "screen", "%s @%dpx" % (shot["scenario"], shot["width"]), v, d, evidence))
    finally:
        pw("close", timeout=60)
        pw("delete-data", timeout=60)
        shutil.rmtree(pw_cwd, ignore_errors=True)
    summary["cand_passthrough"] = sorted(summary["cand_passthrough"])
    return checks, summary


# ---------- report ----------

def write_report(path, ctx, features, checks):
    by = {}
    for c in checks:
        by.setdefault(c.feature, []).append(c)
    w = []
    w.append("# fork-verify `%s`" % ctx["ref"])
    w.append("")
    w.append("- 후보: `%s` (`%s`), CLI 버전 `%s`" % (ctx["ref"], ctx["sha"], ctx["version"]))
    w.append("- 레지스트리: `%s` 기준 `fork/features.yml`" % ctx["registry_ref"])
    w.append("- 판정: **%s** (exit %d) · 통과 %d · 실패 %d · 확인 불가 %d · 해당 없음 %d" % (
        "실패 있음" if ctx["exit"] else "실패 없음", ctx["exit"], *[sum(1 for c in checks if c.verdict == v) for v in (PASS, FAIL, UNVERIFIED, NA)]))
    w.append("- 시각: %s → %s (%s)" % (ctx["started"], ctx["finished"], ctx["elapsed"]))
    w.append("")
    w.append("## 개조별 결과")
    w.append("")
    w.append("| 개조 | 종류 | 판정 | 시험 | 시나리오 | 화면 |")
    w.append("|---|---|---|---|---|---|")
    for f in features:
        cs = by.get(f["id"], [])
        cell = lambda layer: (lambda xs: "-" if not xs else "%s %d/%d" % (VERDICT_KO[feature_verdict(xs)], sum(1 for x in xs if x.verdict == PASS), len(xs)))(
            [c for c in cs if c.layer == layer])
        w.append("| `%s` | %s | **%s** | %s | %s | %s |" % (f["id"], f.get("kind"), VERDICT_KO[feature_verdict(cs)], cell("test"), cell("scenario"), cell("screen")))
    w.append("")
    w.append("## 항목별")
    w.append("")
    for f in features:
        cs = by.get(f["id"], [])
        if not cs:
            continue
        w.append("### `%s` — %s" % (f["id"], VERDICT_KO[feature_verdict(cs)]))
        w.append("")
        for c in cs:
            ev = "" if not c.evidence else " ([근거](%s))" % os.path.relpath(c.evidence[0], path.parent)
            w.append("- %s **%s** · %s: %s%s" % ({"test": "시험", "scenario": "시나리오", "screen": "화면"}[c.layer], VERDICT_KO[c.verdict], c.name, c.detail, ev))
        w.append("")
    w.append("## 후보 스택")
    w.append("")
    for line in ctx["stack_lines"]:
        w.append("- " + line)
    w.append("")
    w.append("## 운영 안전")
    w.append("")
    for line in ctx["safety_lines"]:
        w.append("- " + line)
    w.append("")
    w.append("## 로그")
    w.append("")
    w.append("`%s`" % os.path.relpath(ctx["logdir"], path.parent))
    path.write_text("\n".join(w) + "\n")


# ---------- main ----------

def parse_args(argv):
    ap = argparse.ArgumentParser(prog="fork-verify.sh", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ref")
    ap.add_argument("--registry-ref", default="HEAD")
    ap.add_argument("--version", default="")
    ap.add_argument("--backup", default="")
    ap.add_argument("--host", default=os.environ.get("FORK_VERIFY_HOST", "calabii-02"))
    ap.add_argument("--port-base", type=int, default=23010)
    ap.add_argument("--repo-url", default="https://github.com/honki12345/multica")
    ap.add_argument("--screen-input", default="", help="upstream-triage --json output; its screen_inputs add B captures")
    ap.add_argument("--prod-web", default="http://127.0.0.1:13010")
    ap.add_argument("--prod-api", default="http://127.0.0.1:18090")
    ap.add_argument("--prod-config", default="~/.multica/config.json")
    ap.add_argument("--agent-model", default="claude-haiku-4-5")
    ap.add_argument("--hermes-env", default="ABBADO_HERMES_LOCAL_KEY", help="comma list of env vars the test Hermes config needs")
    ap.add_argument("--hermes-installs", default="~/.hermes/installs")
    ap.add_argument("--hermes-path-dirs", default="%s/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" % os.path.expanduser("~"))
    ap.add_argument("--mask", default='[data-slot="sidebar"];[data-mc="page"];[data-mc="chat-window"] [data-slot="chat-message-list"]')
    ap.add_argument("--region-threshold", type=float, default=0.01)
    ap.add_argument("--real-agent", action="store_true", help="also run registry tests marked real_agent (in the test Hermes home)")
    ap.add_argument("--skip", default="", help="comma list of layers to skip: test,scenario,screen")
    ap.add_argument("--keep", action="store_true", help="leave the stack and test runtime up (debugging)")
    ap.add_argument("--out", default="")
    return ap.parse_args(argv)


def default_backup():
    files = sorted(glob.glob(os.path.expanduser("~/.local/share/multica-selfhost/backups/*.dump")), key=os.path.getmtime)
    return files[-1] if files else ""


def resolve_version(ref, explicit, short):
    if explicit:
        return explicit.lstrip("v")
    m = re.match(r"^v?(\d+\.\d+\.\d+-hoon\.\d+)$", ref)
    if m:
        return m.group(1)
    tag = git("describe", "--tags", "--exact-match", ref, check=False).stdout.strip()
    m = re.match(r"^v?(\d+\.\d+\.\d+-hoon\.\d+)$", tag)
    if m:
        return m.group(1)
    # Untagged: the `git describe` form a `make build` daemon reports, which the
    # server's CLI version gates accept as a source build (agent.devDescribeRe).
    desc = git("describe", "--tags", "--always", ref, check=False).stdout.strip()
    return desc if re.match(r"^v?\d+\.\d+\.\d+-", desc) else "0.0.0-0-g%s" % short


def _interrupt(signum, _frame):
    raise KeyboardInterrupt("signal %d" % signum)


def main(argv):
    args = parse_args(argv)
    signal.signal(signal.SIGTERM, _interrupt)
    signal.signal(signal.SIGHUP, _interrupt)
    skip = set(filter(None, args.skip.split(",")))
    started = datetime.datetime.now().astimezone()
    try:
        sha = git("rev-parse", "--verify", args.ref + "^{commit}").stdout.strip()
        reg = load_registry(args.registry_ref)
    except RuntimeError as e:
        print("fork-verify: %s" % e, file=sys.stderr)
        return 2
    short = sha[:9]
    version = resolve_version(args.ref, args.version, short)
    out_dir = Path(args.out) if args.out else REPO / "out" / "fork-verify" / slugify_ref(args.ref)
    shutil.rmtree(out_dir, ignore_errors=True)
    logdir = out_dir / "logs"
    logdir.mkdir(parents=True)
    backup = args.backup or default_backup()
    screen_input = json.loads(Path(args.screen_input).read_text()) if args.screen_input else None

    checks = []
    active = [f for f in reg.get("features", []) if f.get("status") == "active"]
    present = []
    for f in active:
        if feature_in_candidate(f, sha):
            present.append(f)
        else:
            checks.append(Check(f["id"], "test", "개조 커밋", NA, "후보 `%s`에 이 개조의 커밋이 없음(후보가 개조보다 오래됨)" % short))
    for f in reg.get("features", []):
        if f.get("status") == "planned":
            checks.append(Check(f["id"], "scenario", "계획 중", NA, "status: planned, 시험하지 않음"))
    features_report = [f for f in reg.get("features", []) if f.get("status") in ("active", "planned")]

    tree = Path(tempfile.mkdtemp(prefix="fork-verify-tree-"))
    stack = Stack(args, sha, short, version, "fv" + short[:7], logdir)
    res = None
    stack_lines, safety_lines = [], []
    timings = {}
    try:
        t = time.time()
        git("archive", "--format=tar", "-o", str(tree / "src.tar"), sha)
        run(["tar", "-xf", str(tree / "src.tar"), "-C", str(tree)], check=True)
        (tree / "src.tar").unlink()
        cli_bin = tree / "fv-multica"
        p = run(["go", "build", "-ldflags", "-X main.version=%s -X main.commit=%s" % (version, short), "-o", str(cli_bin), "./cmd/multica"],
                cwd=str(tree / "server"), env=clean_env(), timeout=900)
        if p.returncode != 0:
            raise RuntimeError("candidate CLI build failed: %s" % p.stderr[-500:])
        timings["export+cli"] = time.time() - t

        need_stack = not ({"scenario", "screen"} <= skip)
        if need_stack:
            if not backup:
                raise RuntimeError("no backup dump found; pass --backup")
            busy = stack.ports_free()
            if busy:
                raise RuntimeError("ports in use: %s (pass --port-base)" % ", ".join(busy))
            t = time.time()
            stack.up(backup)
            stack.seed()
            timings["stack"] = time.time() - t

        if "test" not in skip:
            t = time.time()
            env = clean_env()
            # Never let DB-backed tests fall back to localhost:5432 (another Postgres may live there).
            env["DATABASE_URL"] = (stack.up_ok and stack.gotest_db_url()) or NO_DB_URL
            agent_env = {}
            res_for_env = Resident(args, stack, version, logdir, cli_bin)
            try:
                if args.real_agent:
                    res_for_env.prepare_hermes_home()
                    agent_env = res_for_env.base_env()
                checks += run_go_tests(tree, present, env, logdir, args.real_agent, agent_env)
            finally:
                res_for_env.cleanup()
            checks += run_vitest(tree, present, clean_env(), logdir)
            timings["tests"] = time.time() - t

        if "scenario" not in skip:
            t = time.time()
            res = Resident(args, stack, version, logdir, cli_bin)
            scen = [f for f in present if f.get("kind") in ("server", "cli", "daemon")]
            try:
                checks += run_scenarios(res, stack, scen, version, logdir)
            except Exception as e:  # one broken layer must not hide the screens
                checks.append(Check("(run)", "scenario", "시나리오 단계", FAIL, "중단: %s" % describe_error(e)))
                log("scenarios aborted: %s" % describe_error(e))
            res.stop()
            timings["scenarios"] = time.time() - t
            stack.info["stats_after_scenarios"] = stack.remote_stats()

        if "screen" not in skip:
            t = time.time()
            prod = prod_context(args)
            scr, summary = run_screens(args, stack, prod, [f for f in present if f.get("kind") == "web-ui"], out_dir, logdir, screen_input)
            checks += scr
            timings["screens"] = time.time() - t
            safety_lines.append("운영 화면: 런타임 소유자 PAT로 읽기만 함. GET 외 요청 %d건을 브라우저에서 막음(예: %s). 실시간 소켓은 빈 스텁."
                                % (summary.get("prod_blocked", 0), ", ".join(summary.get("prod_blocked_sample", [])[:3]) or "없음"))
            safety_lines.append("채팅 목록·대기 작업 API는 양쪽 모두 가짜 데이터(fork-verify chat 01~%02d)로 답함. 실제 채팅 제목은 화면에 나오지 않음." % FIXTURE_CHATS)
            safety_lines.append("가림: %s 영역 흐림 처리." % args.mask.replace(";", ", "))
            safety_lines.append("후보 화면은 운영에서 받은 GET 응답 %d건을 재생. 운영에 없던 요청은 후보 서버 시험 작업 공간으로 보냄: %s"
                                % (summary.get("replayed", 0), ", ".join("`%s`" % x for x in summary.get("cand_passthrough", [])[:8]) or "없음"))
    except (Exception, KeyboardInterrupt) as e:  # report what ran so far, then clean up
        checks.append(Check("(run)", "scenario", "실행", FAIL, "중단: %s" % (describe_error(e) or type(e).__name__)))
        log("aborted: %s" % describe_error(e))
    finally:
        # A second signal during cleanup must not stop it.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        steps = [res.stop if res else None]
        if not args.keep:
            steps += [res.cleanup if res else None, stack.down if stack.remote_started else None,
                      lambda: shutil.rmtree(tree, ignore_errors=True)]
        for step in steps:
            if step:
                try:
                    step()
                except (Exception, KeyboardInterrupt) as e:  # keep cleaning up; report it
                    checks.append(Check("(run)", "scenario", "정리", FAIL, "정리 실패: %s" % (describe_error(e) or type(e).__name__)))
        if not args.keep:
            left = stack.info.get("left_after_down", "0 0 0")
            if stack.remote_started and left != "0 0 0":
                checks.append(Check("(run)", "scenario", "정리", FAIL, "후보 스택 정리 뒤 컨테이너/볼륨/이미지가 남음: %s" % left))

    if stack.info:
        i = stack.info
        stack_lines.append("기기: `%s` (빌드·DB·서버). 이 Mac: 화면 브라우저, 시험 데몬·Hermes gateway, Go·vitest 시험." % args.host)
        stack_lines.append("백업: `%s` 복원 → 표 %s개, 마이그레이션 `%s` → `%s`(후보 기동 때 적용)." % (
            os.path.basename(backup), i.get("tables", "?"), i.get("migrations_before", "?"), i.get("migrations_after", "?")))
        stack_lines.append("걸린 시간: 이미지 빌드 %ss, 복원 %ss, 기동 %ss, 전송 등 %ss." % (
            i.get("build_secs", "?"), i.get("restore_secs", "?"), i.get("boot_secs", "?"), i.get("upload_secs", "?")))
        if i.get("stats"):
            stack_lines.append("기동 직후 자원: " + "; ".join(i["stats"]))
        if i.get("stats_after_scenarios"):
            stack_lines.append("시나리오 뒤 자원: " + "; ".join(i["stats_after_scenarios"]))
        stack_lines.append("정리: %s" % ("남긴 채 종료(--keep)" if args.keep else "컨테이너/볼륨/이미지 남은 수 %s" % i.get("left_after_down", "?")))
    stack_lines.append("단계별 시간: " + ", ".join("%s %.0fs" % kv for kv in timings.items()))
    safety_lines.append("후보 DB는 운영 백업 사본. 시험 사용자 `fork-verify@example.invalid`와 빈 작업 공간 `fork-verify`만 새로 만들어 씀. 운영 컨테이너·DB·데몬은 건드리지 않음.")
    safety_lines.append("시험 데몬·Hermes gateway: 별도 HOME·HERMES_HOME(임시 폴더), 프로필 `fork-verify`, 자동 업데이트·재시작 끔. 끝나면 프로세스와 폴더 삭제.")

    finished = datetime.datetime.now().astimezone()
    ctx = {"ref": args.ref, "sha": sha, "version": version, "registry_ref": args.registry_ref,
           "started": started.strftime("%Y-%m-%d %H:%M %Z"), "finished": finished.strftime("%H:%M"),
           "elapsed": "%d분 %d초" % divmod(int((finished - started).total_seconds()), 60),
           "exit": exit_code(checks), "stack_lines": stack_lines, "safety_lines": safety_lines, "logdir": logdir}
    write_report(out_dir / "report.md", ctx, features_report + ([{"id": "(run)", "kind": "-"}] if any(c.feature == "(run)" for c in checks) else []), checks)
    (out_dir / "result.json").write_text(json.dumps({"ref": args.ref, "sha": sha, "exit": ctx["exit"],
                                                     "checks": [dataclasses.asdict(c) for c in checks]}, indent=1, ensure_ascii=False))
    print("fork-verify: %s exit=%d pass=%d fail=%d unverified=%d n/a=%d report=%s" % (
        args.ref, ctx["exit"], *[sum(1 for c in checks if c.verdict == v) for v in (PASS, FAIL, UNVERIFIED, NA)], out_dir / "report.md"))
    return ctx["exit"]


def clean_env():
    return {k: v for k, v in os.environ.items() if not k.startswith("MULTICA_")}


def prod_context(args):
    cfg = json.load(open(os.path.expanduser(args.prod_config)))
    token, ws = cfg["token"], cfg["workspace_id"]
    wss = api_json(args.prod_api, "/api/workspaces", token, ws) or []
    slug = next(w["slug"] for w in wss if w["id"] == ws)
    return {"web": args.prod_web, "token": token, "ws_id": ws, "slug": slug}


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

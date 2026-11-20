# honki12345/multica — fork notes

This repository is a modified fork of [Multica](https://github.com/multica-ai/multica)
by Index Labs (Hong Kong) Limited, distributed under the Multica License
(`LICENSE`: Part I additional conditions + Apache License 2.0). It is built on
Multica; the upstream project lives at https://github.com/multica-ai/multica.

> **Agents and contributors:** a PR that adds, changes or drops a fork feature
> must update [`fork/features.yml`](fork/features.yml) in the same PR. The fork
> check (`scripts/hoon/features-check.sh`) fails when a changed file belongs to
> no feature. See "Fork feature registry" below. Checks run locally and are
> reported as a PR comment; this fork does not use GitHub Actions, the same
> checks run locally (`scripts/hoon/fork-pr-check.sh`, see "Verification").

## Upstream base

| Item | Value |
|---|---|
| Upstream remote | `upstream` → `https://github.com/multica-ai/multica.git` |
| Current upstream base tag | `v0.11.0` (`cb190810a659c1a61c4a86d9f6ecfc9df4b086d8`), merged into `main` |
| Previous base tags | `v0.10.0` (`2fcb424b72b024f65161809081009063846ea44d`), `v0.9.0` (`8cd8a2db978d532d8627c78cd29f05deab6c6f17`) |
| Fork trunk | `main` |
| First fork release | `v0.9.0-hoon.1` |

## Tracking policy (merge, not rebase)

- Absorb upstream by **merging upstream release tags** into our `main`
  (`git merge v0.X.Y` on a `merge/v0.X.Y` branch, then PR into `main`),
  following "Upstream absorb gate" below: nothing is tagged, built or deployed
  before the user approves the absorb card.
- Do **not** rebase our commits onto each new upstream release; this fork is
  its own line and its history is kept.
- Individual upstream `main` commits that we need before a release are
  **cherry-picked** (`git cherry-pick -x`) so the upstream origin stays visible.
- When upstream fixes the same problem as one of our changes, drop ours in the
  merge and say why in the merge commit body. Set that feature's `status:
  dropped` in `fork/features.yml` in the same merge.
- Never push to upstream or open PRs there from this repository's automation.

## Version format

`<upstream base>-hoon.N`, e.g. `0.9.0-hoon.1` (tag `v0.9.0-hoon.1`).

A bare `X.Y.Z` must not be used: the daemon treats it as an official release
(`server/internal/cli/update.go` `IsReleaseVersion`) and, with auto-update on,
would replace our binary with the official one. Image tags and
`-X main.version` use the same string.

## License obligations

1. Keep `LICENSE` complete and unmodified (Part I 3(d)).
2. Keep `NOTICE`; only append the line stating this is a modified fork
   (Apache 2.0 §4(d)).
3. Mark every modified upstream file with a prominent notice
   `Modified by honki12345, 2026: <one-line summary>` (Apache 2.0 §4(b)).
   Files that cannot carry a comment are listed below instead.
4. Preserve all copyright, patent, trademark and attribution notices in the
   source (Apache 2.0 §4(c)).
5. Do not remove or change the Multica name, logo, or copyright/attribution
   shown by a Multica user interface (`apps/web`, `apps/desktop`,
   `apps/mobile`, `packages/views`, `packages/ui`, the web image, and any
   desktop/mobile build) (Part I 1(b)).
6. Do not offer this fork as a hosted or embedded service to anyone outside
   our own organization (Part I 1(a)).
7. If only the server/daemon/CLI is redistributed or operated without a
   Multica UI, user-facing docs must say it is built on Multica and link to
   https://github.com/multica-ai/multica (Part I 1(c)).

## UI areas that must not be rebranded

`apps/web/`, `apps/desktop/`, `apps/mobile/`, `packages/views/`, `packages/ui/`
— functional changes are allowed there, but the Multica product name, logo
assets and displayed copyright/attribution stay as upstream ships them.

## Verification (local, no GitHub Actions)

This fork does not use GitHub Actions; the same checks run locally. Do not
enable Actions or treat a missing `gh pr checks` result as a blocker or a
human task. The workflow files stay in the tree as the description of what to
run (`.github/workflows/fork-license.yml`); every check is run locally
(calabii-macstudio or calabii-02) on the PR head, and the result is posted as
one PR comment.

`scripts/hoon/fork-pr-check.sh` does all of this in one command:

```bash
scripts/hoon/fork-pr-check.sh plan 21          # which checks the changed files call for
scripts/hoon/fork-pr-check.sh run 21 --post    # run them on a clean worktree of the head, post the comment
scripts/hoon/fork-pr-check.sh gate 21          # gate=ok head=<sha> only if the newest check comment is green for today's head
gh pr merge 21 --merge --match-head-commit <sha from gate=ok>
bash scripts/hoon/fork-pr-check.test.sh        # throwaway repos, stub gh, no network
```

`run` fetches the PR head, checks that it is the head GitHub reports, and runs
the checks in a temporary detached worktree that is always removed. The
checks are chosen from the files the PR changes:

| Changed | Check |
|---|---|
| anything | `license-check.sh`, `features-check.sh` (after fetching upstream tags into `refs/upstream-tags/`), `git diff --check` |
| `scripts/hoon/X*` | `scripts/hoon/X.test.sh` when it exists at the head (also when `X.sh` was deleted), `shellcheck -S warning` on changed `.sh` that still exist |
| `fork/features.yml` | `features-check.test.sh` |
| `.github/**`, `scripts/*.mjs` | `node --test scripts/ci-scope.test.mjs` |
| `server/go.mod`, `server/go.sum` | `cd server && go build ./... && go vet ./cmd/... ./internal/... ./pkg/...` (never the full `go test ./...`: the Mac is shared) |
| `server/**/*.go` | `go test -p 2 <changed packages>`; DB-backed tests skip (no `DATABASE_URL`). A deleted Go file selects its package dir if the dir still has Go files, else the module build above. Run them against a throwaway `pgvector/pgvector:pg17` on calabii-02 when the PR touches SQL |
| TS/TSX in `apps/` or `packages/` (not mobile), `pnpm-lock.yaml`, `pnpm-workspace.yaml`, any `package.json`, `tsconfig*.json`, `turbo.json` (root, `apps/`, `packages/`, not mobile) | `pnpm install --frozen-lockfile --prefer-offline`, `pnpm typecheck`, and `vitest related <changed files that still exist> --run --maxWorkers=2` per package (skipped when none; no full `vitest run`) |

The comment carries the full 40-character head SHA, the base, the machine,
each command with its exit code, result line and time, the verdict, and a
marker line `<!-- fork-pr-check pr=<n> head=<sha> verdict=pass|fail -->`.
`gate` reads the newest valid comment from an owner/member/collaborator. Valid
means laid out line by line exactly as `run` writes it: the header, the PR,
head, base, machine and time lines, the table, the verdict line, the fixed
trailer, and the marker last, with the marker's sha equal to the head line.
For `verdict=pass` the verdict line must read `판정: 통과 (실패 0)`, every row
must have exit code 0, and the `license-check.sh` and `features-check.sh` rows
must be there. CRLF line endings are accepted; any other carriage return,
and any other line (a code block, quote, HTML block or prose), voids
the comment, so a pasted or hand-edited copy does not open the gate; an
invalid newer comment is ignored.

Merge only when `gate` says `ok`: zero failures for the current head. A failure
judged pre-existing upstream (the same test also fails on the clean upstream
base tag) is not waived by the script; rerun without it or record the
evidence in a follow-up comment and get review agreement. A new head needs a
new run and a new comment.

## License check

`scripts/hoon/license-check.sh` is one of the local checks above (also documented
in `.github/workflows/fork-license.yml`). The base is the newest upstream
`vX.Y.Z` tag merged into the head (upstream tags are fetched into
`refs/upstream-tags/`).

| Check | Result |
|---|---|
| `LICENSE` byte-identical to the base tag | fail |
| every base-tag `NOTICE` line still present | fail |
| every upstream file changed or deleted since the base tag has `Modified by honki12345` in its first 30 lines, or is listed in the table below | fail |
| a newer upstream tag ships a different `LICENSE` | warning |
| UI areas: logo/brand asset changed or deleted, or a non-comment line mentioning `Multica` disappeared | warning |

Run it locally:

```bash
git fetch --no-tags upstream '+refs/tags/v*:refs/upstream-tags/v*'
bash scripts/hoon/license-check.sh
bash scripts/hoon/license-check.test.sh   # throwaway repos, no network
```

## Modified files without an inline notice

| File | Reason | Change |
|---|---|---|
| `server/pkg/db/queries/supplement.sql` | sqlc copies leading comments into generated Go, so a header would leak into generated code | allow the `hermes` provider for task supplements |
| `server/pkg/db/generated/supplement.sql.go` | generated by sqlc (`DO NOT EDIT`) | regenerated from the query change above |
| `server/pkg/db/queries/inbox.sql` | sqlc copies leading comments into generated Go | cherry-picked from upstream #10861 (inbox owner gate) |
| `server/pkg/db/queries/inbox_archive.sql` | sqlc copies leading comments into generated Go | cherry-picked from upstream #10861 (archive exact-type filter) |
| `server/pkg/db/generated/inbox.sql.go` | generated by sqlc (`DO NOT EDIT`) | regenerated by upstream #10861 from the query change above |
| `server/pkg/db/generated/inbox_archive.sql.go` | generated by sqlc (`DO NOT EDIT`) | regenerated by upstream #10861 from the query change above |
| `server/internal/service/builtin_skills/multica-platform/SKILL.md` | shipped to agents verbatim as skill content; its body length is tested | cherry-picked from upstream #10861 (inbox routing row) |
| `packages/views/locales/en/settings.json` | JSON has no comment syntax | labels for the chat previous/next sent-message shortcuts (CALA-281) and the focus region keys (CALA-332) |
| `packages/views/locales/es/settings.json` | JSON has no comment syntax | labels for the chat previous/next sent-message shortcuts (CALA-281) and the focus region keys (CALA-332) |
| `packages/views/locales/fr/settings.json` | JSON has no comment syntax | labels for the chat previous/next sent-message shortcuts (CALA-281) and the focus region keys (CALA-332) |
| `packages/views/locales/ja/settings.json` | JSON has no comment syntax | labels for the chat previous/next sent-message shortcuts (CALA-281) and the focus region keys (CALA-332) |
| `packages/views/locales/ko/settings.json` | JSON has no comment syntax | labels for the chat previous/next sent-message shortcuts (CALA-281) and the focus region keys (CALA-332) |
| `packages/views/locales/ru/settings.json` | JSON has no comment syntax | labels for the chat previous/next sent-message shortcuts (CALA-281) and the focus region keys (CALA-332) |
| `packages/views/locales/zh-Hans/settings.json` | JSON has no comment syntax | labels for the chat previous/next sent-message shortcuts (CALA-281) and the focus region keys (CALA-332) |
| `packages/views/locales/zh-Hant/settings.json` | JSON has no comment syntax | labels for the chat previous/next sent-message shortcuts (CALA-281) and the focus region keys (CALA-332) |
| `packages/views/locales/en/chat.json` | JSON has no comment syntax | toast when saving the pinned-chat order fails (CALA-316) |
| `packages/views/locales/es/chat.json` | JSON has no comment syntax | toast when saving the pinned-chat order fails (CALA-316) |
| `packages/views/locales/fr/chat.json` | JSON has no comment syntax | toast when saving the pinned-chat order fails (CALA-316) |
| `packages/views/locales/ja/chat.json` | JSON has no comment syntax | toast when saving the pinned-chat order fails (CALA-316) |
| `packages/views/locales/ko/chat.json` | JSON has no comment syntax | toast when saving the pinned-chat order fails (CALA-316) |
| `packages/views/locales/ru/chat.json` | JSON has no comment syntax | toast when saving the pinned-chat order fails (CALA-316) |
| `packages/views/locales/zh-Hans/chat.json` | JSON has no comment syntax | toast when saving the pinned-chat order fails (CALA-316) |
| `packages/views/locales/zh-Hant/chat.json` | JSON has no comment syntax | toast when saving the pinned-chat order fails (CALA-316) |

New files added by this fork (`server/cmd/multica/resident_task*.go`,
`server/internal/daemon/resident_task_context*.go`,
`server/internal/daemon/execenv/hermes_resident_gateway_test.go`,
`server/pkg/agent/hermes_supplement*.go`) are not upstream files and carry no
modification notice.

## Fork changes

The list of fork features lives in [`fork/features.yml`](fork/features.yml),
the only copy. Each entry records the files we changed or added, the
surrounding code that can break it (`watch`), how to spot upstream shipping the
same thing (`upstream_equivalent`), its tests and runnable scenarios, and when
to drop it (`drop_when`). Upstream triage, fork verification and the absorb
gate read that file; do not repeat its contents here.

## Fork feature registry

### Rule for every change

Adding, changing or dropping a fork feature updates `fork/features.yml` in the
same PR. `scripts/hoon/features-check.sh` is one of the local checks in
"Verification" and fails the PR when the registry is out of step.

| Check | Result |
|---|---|
| registry format (required keys, `kind`, `status`, unique `id`, quoted and existing `origin.commits`, non-empty scenario `steps`/`expect`, no `#` after an unquoted value on its line) | fail |
| an active feature's `files` entry is missing (an upstream file the feature deletes is fine); an active or planned feature's `watch` path matches nothing | fail |
| a file that differs from the base tag (changed, added or deleted) is in no active feature's `files` and no `infrastructure` entry | fail |
| an active or planned feature's `tests` entry names a Go test function or vitest file/case that does not exist | fail |
| an upstream file in `files` is identical to the base tag | warning |
| a `planned` feature's file already differs from the base tag | warning |

`dropped` features are format-checked only: their files, watch paths and tests
may be gone. The registry is read from the committed tree (`HEAD` by default), so commit
before running it. It needs PyYAML (`python3 -c 'import yaml'`) or `uv`.

```bash
git fetch --no-tags upstream '+refs/tags/v*:refs/upstream-tags/v*'
bash scripts/hoon/features-check.sh
bash scripts/hoon/features-check.test.sh   # throwaway repos, no network
```

### Entry fields

| Field | Meaning |
|---|---|
| `id`, `summary` | kebab-case id, one line |
| `status` | `active` (shipped), `planned` (in progress, not merged), `dropped` |
| `kind` | `server` / `cli` / `daemon` / `web-ui` / `desktop` |
| `cards` | Multica cards (`CALA-72`) |
| `origin` | `type: ours` or `upstream-cherry-pick` with `upstream_pr`; `commits` on this fork |
| `files` | upstream files we modified and files we added (tests included) |
| `watch` | `{path, why}`: files or globs we did not change whose changes can break the feature, chosen from its imports and callers |
| `upstream_equivalent` | `prs`, `symbols`, `keywords` that mean upstream shipped the same feature |
| `tests` | `{go: <package dir>, name: <TestFunc>}` or `{vitest: <file>, name: <case>}`; `tags`/`real_agent` for gated tests; `tests_gap` when none exists |
| `scenarios` | `name`, `setup`, numbered `steps`, `expect`; web UI adds `path`, `widths`, `selectors` |
| `drop_when` | the condition that lets us delete the feature |

Files that are fork upkeep rather than a feature (`NOTICE`, `FORK.md`,
`fork/**`, `scripts/hoon/**`, the fork workflow) are listed under
`infrastructure`.

Quote a value that contains ` #` (`drop_when: "... PR #10119 ..."`). Unquoted,
YAML reads the rest as a comment. Comments go on their own line: a `#` after
an unquoted value on the same line fails `features-check.sh`, because YAML
cannot tell a cut value from a trailing comment.

## Upstream triage

`scripts/hoon/upstream-triage.sh <from-tag> <to-ref>` reads what upstream
changed between two refs and says what it means for this fork. It sorts every
non-merge commit against the registry:

| Class | Rule | What to do |
|---|---|---|
| A | touches a file in an active feature's `files` | conflict or behaviour risk; ⚔️ marks files `git merge-tree` reports as conflicting with `--fork-ref` |
| B | touches a `watch` path, or a planned feature's `files` | surrounding change; run that feature's scenarios (screen comparison input) |
| C | PR number in `upstream_equivalent.prs`, a `symbols` entry that is new since `<from-tag>`, or a `keywords` phrase in the subject, PR title, PR labels or release-notes line | candidate: upstream may ship our feature; check `drop_when` |
| D | migration, `.env.example`, compose, Dockerfile or selfhost script, or a new env key (`.env.example`, `${VAR}` in compose, `os.Getenv` in Go) absent at `<from-tag>` | backup and config check before deploy |
| E | `feat` subject naming chat, inbox, daemon, hermes, cli or autopilot | candidate: worth absorbing |
| F | none of the above | |

A commit can be in several classes. It also builds the CLI at both refs and
diffs the `--help` command trees (needs Go; falls back to the new cobra `Use:`
lines in `server/cmd/multica`). C and E are keyword matches only: the report
ends with the instruction for the absorb run to read the PR bodies and settle
them. The script calls no LLM, prints the same output for the same refs, and
always exits 0 (`triage_status=error` on failure).

```bash
scripts/hoon/upstream-triage.sh v0.10.0 v0.11.0 --fork-ref v0.10.0-hoon.1 --json out.json > report.md
bash scripts/hoon/upstream-triage.test.sh   # throwaway repos, no network
```

The report ends with `--- triage keys` and one `triage_*=` key per line
(counts, feature ids, migration range, new env keys, new CLI commands). The
JSON has the same classification plus `screen_inputs`, the B paths per
feature. Test overrides (`TRIAGE_RELEASE_NOTES_OVERRIDE`,
`TRIAGE_PRS_OVERRIDE`, `TRIAGE_CLI_OVERRIDE`) are listed at the top of the
script. It reads the registry from `--registry-ref` (default `HEAD`), so a
triage of an old range uses today's registry.

## Fork verification

`scripts/hoon/fork-verify.sh <ref>` checks that every active feature in the
registry still works on a candidate (normally the absorb branch
`merge/vX.Y.Z`), against real data and next to the production screens. It
writes `out/fork-verify/<ref>/report.md` (one row per feature: pass, fail,
unverified, n/a; then every check with its evidence) and exits 1 when anything
failed.

| Layer | What runs | Where |
|---|---|---|
| test | each feature's `tests`: `go test -run` per package (`-p 2`), vitest files/cases (`--maxWorkers=2`); `real_agent` tests only with `--real-agent` | this Mac, on an export of the candidate |
| scenario | `server`/`cli`/`daemon` scenarios for real: a resident test issue (`issue get`, `daemon status`, `repo checkout`, `environment list`, `ls -a ..`), a steer (comment with `--steer` during `sleep 60`, the same turn must answer `CODE=PINEAPPLE`), Quick Create through `POST /api/issues/quick-create`, and the inbox CLI reads | candidate stack + a test daemon and test Hermes gateway on this Mac |
| screen | `web-ui` scenarios: production and candidate web in the same headless browser at each `widths` entry; `production \| candidate \| diff` sheets and the pixel share that changed in the bottom bar; DOM selectors and the chat-bar probe (chip count, no `+N`, wheel scroll, click opens the window) | this Mac (`playwright-cli`) |

The candidate stack runs on **calabii-02** (amd64, idle): the candidate's
backend and web images are built there from `git archive` (about 6 minutes,
both in parallel), the newest pre-deploy backup
(`~/.local/share/multica-selfhost/backups/*.dump`) is restored into its own
`pgvector/pgvector:pg17`, and the backend applies the candidate's migrations to
that copy on boot, so a new migration runs on production-shaped data. Every
container, volume, network and image is named `fv-<sha7>-*` and removed at the
end. This Mac only opens an SSH tunnel; it never runs the stack, Supabase or a
browser container.

Safety:

- **Production is read only.** The screen layer uses the runtime owner's PAT
  from `~/.multica/config.json` in a throwaway browser context that aborts
  every non-GET request (any origin or path) and stubs every WebSocket. The
  report counts the blocked writes. The candidate replays the GET responses
  production returned in the same run, so both draw the same data; the chat
  list and pending tasks are a synthetic fixture on both sides, so no real chat
  title appears. Sidebar, page body and chat messages are blurred.
- **Test identity only.** The candidate database gets a new user
  `fork-verify@example.invalid` with an empty workspace `fork-verify` and a
  random PAT. The backend runs with `APP_ENV=development` and a random
  `MULTICA_DEV_VERIFICATION_CODE`, never printed.
- **Test runtime only.** The test daemon (profile `fork-verify`, its own health
  port, auto-update and auto-reload off) and the test Hermes gateway
  (`MULTICA_RESIDENT_OWNER=1`) run under a temporary `HOME`/`HERMES_HOME`.
  They share only the Hermes dependency install (`~/.hermes/installs`) and take
  the model key from the environment (`--hermes-env`). `~/.multica`, the
  production daemon and the production gateway are untouched.

```bash
scripts/hoon/fork-verify.sh merge/v0.12.0 --screen-input triage.json   # B paths add captures
scripts/hoon/fork-verify.sh v0.11.0-hoon.1 --skip test                 # scenarios and screens only
bash scripts/hoon/fork-verify.test.sh                                   # judging logic, no stack
```

A feature whose `origin.commits` are not in the candidate is reported n/a, so
an older tag can be verified with today's registry (`--registry-ref`). A
scenario fork-verify has no runner for is reported unverified with that
reason; add a runner in `fork-verify/fork_verify.py` when adding a feature
whose scenario is not covered.

## Upstream absorb gate

Every upstream tag is absorbed by one Multica card that runs these steps in
order and leaves one card comment per step. The daily fork check creates the
card with the triage report and these steps in its description.

1. **Merge.** On `merge/vX.Y.Z` from `main`: `git merge vX.Y.Z`, resolve
   conflicts (regenerate sqlc output instead of hand-merging it), `go build
   ./...`, update "Upstream base" above.
2. **Triage.** `scripts/hoon/upstream-triage.sh v<old> vX.Y.Z --fork-ref main
   --json triage.json > triage.md`. Read the PR body of every C and E
   candidate (`gh pr view <n> -R multica-ai/multica`) and settle it: C
   버림 / 줄임 / 유지, E 흡수 / 보류 / 무관, each with its reason.
   1. **Upstream first.** For every `active` and `planned` feature and every
      open card of the Multica project that is not in the registry, decide
      상류로 대체 / 상류 위에 남은 것만 / 우리 것 유지 with evidence (PR,
      file, test result). Replace or shrink means: remove or cut our code on
      the same merge branch and set the registry entry to `dropped` (or shrink
      its `files`). A card that is planned and not deployed stops now, with
      the reason and the upstream PR on the card. Removing a deployed feature
      waits for the approval in step 5. Keep needs the user's answer.
      상류에 없음 records that upstream ships nothing equivalent in the range.
      `scripts/hoon/absorb-gate.sh template --triage triage.json --cards
      <issue list json> --exclude-card <absorb card>` writes the decisions
      file with one row per item; every row needs a verdict. The card list
      must be complete: `multica issue list --project <id> --output json
      --limit 100 --fields identifier,title,status > cards.json`, then check
      `has_more` is `false` and `total` equals the number of issues. If not,
      page with `--offset` and merge the pages into one list (a bare JSON list
      of issues works). A later page (`offset` > 0) or a list shorter than
      `total` is refused, so open cards cannot drop out silently.
3. **Verify.** `scripts/hoon/features-check.sh --head merge/vX.Y.Z` and
   `scripts/hoon/fork-verify.sh merge/vX.Y.Z --screen-input triage.json
   --real-agent` (B paths add the surrounding screens).
4. **PR, review, merge.** Fork PR, independent review (plus a migration
   review when the tag ships migrations), `fork-pr-check.sh run <n> --post`,
   then `fork-pr-check.sh gate <n>` and merge with `--match-head-commit` on
   the gate's SHA. A tag-only rehearsal stops before this step.
5. **Stop for approval.** `scripts/hoon/absorb-gate.sh comment --triage
   triage.json --decisions decisions.yml --verify out/fork-verify/<ref>
   --cards cards.json --exclude-card <absorb card> --registry-ref
   merge/vX.Y.Z --candidate merge/vX.Y.Z --triage-md triage.md --pr <url>
   --merge-commit <sha> --pr-check <url> --tag vX.Y.Z-hoon.1` renders the
   single approval comment: the triage summary, the upstream-first table, the
   C/E table, the test table and the screen captures listed after
   `--- attachments` (attach them with `multica issue comment add
   --attachment`). The card goes to `in_review`. Run it inside the fork
   checkout. The script refuses to render (exit 2) unless:
   - the decisions hold exactly one upstream-first row per active/planned
     registry feature (read at `--registry-ref`) and per open card outside the
     registry (`--cards` is required and must be the whole list: `has_more:
     true`, `offset` > 0 and fewer issues than `total` are refused). Missing,
     duplicate and unknown ids are listed on stderr;
   - `--candidate` (the merge branch head that was verified and is up for
     approval) is the commit `fork-verify` ran on: `result.json`'s `sha` equals
     `git rev-parse <candidate>^{commit}`.
   The comment starts with `배포 보류` (nothing is deployed) when the
   `--merge-commit` has another tree than the candidate (`검증한 트리와 병합
   커밋이 다름`), when `result.json` has no checks, or when an active registry
   feature has no check in it, not even `n/a` (`검증 결과에 없는 개조 N건`),
   or when a feature that ran lacks a layer its registry entry calls for: a
   `tests` list needs a `test` check, `scenarios` on a server/cli/daemon
   feature a `scenario` check, `scenarios` on a web-ui feature a `screen`
   check (`검증하지 않은 층 N건 (<id>:<layer>)`). So `fork-verify --skip screen`
   cannot be approved. A feature whose checks are all `n/a` owes no layer.
   No tag, build or deploy before the user approves on the card.
6. **After approval.** Tag `vX.Y.Z-hoon.1` on the merge commit, back up the
   database (`pg_dump -Fc`), `scripts/hoon/release.sh release vX.Y.Z-hoon.1`,
   then rerun the screen layer against production
   (`scripts/hoon/fork-verify.sh vX.Y.Z-hoon.1 --skip test,scenario`).

```bash
bash scripts/hoon/absorb-gate.test.sh   # fixtures only, no network
```

## Deploy and rollback (self-host on calabii-macstudio)

`scripts/hoon/release.sh` builds, swaps in, verifies, and rolls back the
backend image, the web image and the resident CLI/daemon binary from one ref.
Tests: `bash scripts/hoon/release.test.sh` (stubbed docker/curl, no real
deploy).

| Thing | Value |
|---|---|
| Compose | `~/.local/share/multica-selfhost/` (`docker-compose.selfhost.yml`, `.env`), project `multica` |
| Services recreated | `backend`, `frontend` only (`up -d --no-deps`); postgres is never touched |
| `.env` keys changed | `MULTICA_IMAGE_TAG`, `MULTICA_BACKEND_IMAGE`, `MULTICA_WEB_IMAGE` only (the script refuses any other diff) |
| Images | `multica-backend-hoon:vX.Y.Z-hoon.N`, `multica-web-hoon:vX.Y.Z-hoon.N` |
| Binary | `~/.local/share/multica-resident/bin/multica`, reports `X.Y.Z-hoon.N` |
| Build output, deploy records | `~/.local/share/multica-resident/releases/<version>/`, `.../releases/deploys/<ts>.env` |

### Release

```bash
git tag -a v0.9.0-hoon.2 -m "..." && git push origin v0.9.0-hoon.2
scripts/hoon/release.sh build  v0.9.0-hoon.2   # git archive of the tag -> CLI + both images
scripts/hoon/release.sh deploy 0.9.0-hoon.2     # backups, .env swap, up -d, binary swap, verify
# or both at once:
scripts/hoon/release.sh release v0.9.0-hoon.2
```

- `build` exports the committed tree (`git archive`), so uncommitted files never
  ship. A version already built from a different commit is refused: bump `N`.
- `deploy` writes `.env.bak-<ts>` and `multica.bak-<ts>` next to the originals,
  records them in `releases/deploys/<ts>.env`, then recreates `backend` and
  `frontend` (the UI drops for a few seconds).
- The binary is replaced by rename. The running daemon keeps its old inode and
  its auto-reload (10-minute tick) restarts into the new version once no task is
  in flight. Confirm with
  `grep 'auto-reload: restarting' ~/.multica/daemon.log | tail -1`
  (`... reports X.Y.Z-hoon.N`). A deploy started from inside a Multica task
  delays that restart until the task ends.
- `verify [version]` (also run by `deploy`): local and public `/login` 200,
  backend `/health` ok with the build's commit, `/api/config` `server_version`,
  and `multica version`.

### Rollback

```bash
scripts/hoon/release.sh rollback
```

Restores the latest deploy record's `.env` backup and binary backup, runs the
same `up -d --no-deps backend frontend`, and re-runs the HTTP checks. The record
is renamed to `.rolledback`, so a second rollback goes one deploy further back.
Database migrations are not reversed: if a release applied a migration, restore
from a `pg_dump` taken before the deploy instead of rolling back blindly.

`scripts/hoon/release.sh status` prints the current image keys, binary version,
containers and last deploy record.

## Desktop app (Mac mini)

The desktop app (`/Applications/Multica.app` on `calabii-macmini`) bundles its
own UI and its own `multica` CLI, which runs that machine's daemon (profile
`desktop-calabii-macstudio.tail37cc38.ts.net-9330`). A web deploy does not
change it; rebuild the app from the same fork tag after each release.

The fork build cannot fall back to an official release:

| Path | Official build | Fork build |
|---|---|---|
| App updates (`electron-builder.yml` `publish`, packaged as `app-update.yml`) | `multica-ai/multica` releases | `honki12345/multica` releases. The Mac mini build (`--dir`) ships no `app-update.yml` at all, so electron-updater fails to load a feed and a manual check reports an error; a zip/dmg build points at the fork, which publishes no desktop assets |
| Automatic update checks (`updater-preferences.ts` default) | on | off; a user can still turn them on under Settings → Updates |
| Managed CLI repair download (`cli-bootstrap.ts`) | `multica-ai/multica/releases/latest` | `honki12345/multica/releases/latest` |
| Bundled CLI | official binary | built from the same tag, `-X main.version=X.Y.Z-hoon.N` |
| CLI that spawns the daemon (`daemon-manager.ts` `probeCliBinary`, `cli-version-policy.ts`) | first working one of bundled, managed, download, PATH | same order, but a packaged app skips any CLI whose version lacks `-hoon.N`, so an official managed or Homebrew CLI is never used |

The app is ad-hoc signed and not notarized; it is for our own machines only.

### Build and install (run on the Mac mini)

`scripts/hoon/desktop-app.sh` (tests: `bash scripts/hoon/desktop-app.test.sh`).
Build on the Mac mini, not the Mac Studio, which also runs the server and the
gateway.

```bash
# once: get the script from the fork
git clone --depth 1 --branch v0.11.0-hoon.2 https://github.com/honki12345/multica.git ~/.local/share/multica-desktop/src/0.11.0-hoon.2
S=~/.local/share/multica-desktop/src/0.11.0-hoon.2/scripts/hoon/desktop-app.sh

$S build   v0.11.0-hoon.2   # pnpm install + package, ~/.local/share/multica-desktop/apps/<version>/Multica.app
$S install 0.11.0-hoon.2    # refuses while the app daemon has active tasks (--force overrides)
$S verify  0.11.0-hoon.2    # app, bundled CLI and running daemon versions, feed owner, updater off, ShipIt stopped
$S status
```

`install` order matters. Each step stops the run, with the old app still in
place, if it does not take effect:

1. Refuse while the app daemon has active tasks, or when its status cannot be
   read (`--force` skips this).
2. Stop the official updater: `launchctl remove ai.multica.desktop.ShipIt`,
   wait for ShipIt to exit, and move `~/Library/Caches/ai.multica.desktop.ShipIt`
   and `~/Library/Caches/@multicadesktop-updater` next to the backup. An
   official app that already downloaded an update installs it the moment it
   quits.
3. Quit the app (`osascript … quit`) and check that ShipIt did not start again.
4. Write `updater-preferences.json` `{"automaticUpdates": false}`.
5. Copy the new app next to `/Applications/Multica.app`, check it, then move
   the old app to `~/Applications-backup/Multica-<old version>-<ts>.app` and
   the copy into place (a failed move puts the old app back). Clear
   quarantine and open the app.
6. The app sees that the running daemon's version differs from its bundled CLI
   and restarts the daemon once it is idle.

`~/Library/Application Support/Multica` (login, windows, settings) and
`~/.multica` are kept, so the app stays signed in to the same server.

### Gatekeeper

A build made on the machine itself carries no quarantine attribute and opens
directly. A copy downloaded or AirDropped from another Mac does: clear it
before the first launch.

```bash
xattr -dr com.apple.quarantine /Applications/Multica.app
```

(Or right-click → Open once and confirm.)

### Rollback

```bash
$S rollback   # puts back the app recorded in ~/.local/share/multica-desktop/last-backup
```

Rollback stops ShipIt and writes `automaticUpdates: false` before it reopens
the restored app, because an official app defaults to updating itself. Turn
updates on under Settings → Updates only if the official app should update
itself again.

The build needs `pnpm` on PATH (electron-builder runs it to collect node
modules); without a global pnpm the script enables corepack's shim in
`~/.local/share/multica-desktop/corepack-bin`.

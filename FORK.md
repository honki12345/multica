# honki12345/multica — fork notes

This repository is a modified fork of [Multica](https://github.com/multica-ai/multica)
by Index Labs (Hong Kong) Limited, distributed under the Multica License
(`LICENSE`: Part I additional conditions + Apache License 2.0). It is built on
Multica; the upstream project lives at https://github.com/multica-ai/multica.

> **Agents and contributors:** a PR that adds, changes or drops a fork feature
> must update [`fork/features.yml`](fork/features.yml) in the same PR. The fork
> check (`scripts/hoon/features-check.sh`) fails when a changed file belongs to
> no feature. See "Fork feature registry" below. Checks run locally and are
> reported as a PR comment; this fork does not use GitHub Actions (see
> "Verification").

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
  (`git merge v0.X.Y` on a `merge/v0.X.Y` branch, then PR into `main`).
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

This fork does not use GitHub Actions. Do not enable it or treat a missing
`gh pr checks` result as a blocker. The workflow files stay in the tree as the
description of what to run; every check is run locally (calabii-macstudio or
calabii-02) on the PR head, and the result is posted as one PR comment.

1. Check out the PR head in a clean tree and record the full 40-character SHA.
2. Run, as applicable to the change:
   - `bash scripts/hoon/license-check.sh` and `bash scripts/hoon/features-check.sh`
     (after `git fetch --no-tags upstream '+refs/tags/v*:refs/upstream-tags/v*'`)
   - Go tests for the touched packages (`cd server && go test -p 2 <pkgs>`);
     DB-backed packages against a throwaway `pgvector/pgvector:pg17` on calabii-02
   - web: `pnpm typecheck` and `pnpm vitest related <changed files> --run`
     (no full `vitest run`)
   - the fork's own script tests (`scripts/hoon/*.test.sh`) when scripts change
3. Post one PR comment: head SHA, machine, each command with exit code and
   pass/fail counts, and for any failure judged pre-existing, the same test
   failing on the clean upstream base tag.
4. Merge only when that comment shows zero failures other than ones proven
   pre-existing upstream (the same test also fails on the clean upstream base
   tag). Any new failure blocks the merge; `--match-head-commit` pins the SHA
   but does not check results. Merge with
   `gh pr merge --match-head-commit <that SHA>`. A new head needs a new run and
   a new comment.

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
| registry format (required keys, `kind`, `status`, unique `id`, quoted and existing `origin.commits`, non-empty scenario `steps`/`expect`) | fail |
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

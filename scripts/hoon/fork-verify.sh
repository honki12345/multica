#!/usr/bin/env bash
# Fork verification for honki12345/multica (FORK.md "Fork verification").
#
#   scripts/hoon/fork-verify.sh <ref> [--screen-input <upstream-triage.json>] [--backup <dump>]
#       [--registry-ref <ref>] [--version X.Y.Z-hoon.N] [--host calabii-02] [--port-base 23010]
#       [--skip test,scenario,screen] [--real-agent] [--keep] [--out <dir>]
#
# Builds <ref> into a candidate stack on the remote Docker host (backup of the
# self-host restored into its own Postgres, other ports, other names), runs
# every active feature in fork/features.yml against it — registry tests,
# server/cli/daemon scenarios through a test daemon and test Hermes gateway on
# this Mac, web-ui scenarios side by side with production in a headless
# browser — and writes out/fork-verify/<ref>/report.md. The stack and the test
# runtime are removed at the end. Exit 0: no failure; 1: a failure; 2: could
# not start. Never writes to the production containers, DB or daemon.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fork-verify"
if python3 -c 'import yaml, PIL' 2>/dev/null; then
  PY=(python3)
elif command -v uv >/dev/null 2>&1; then
  PY=(uv run -q --no-project --with pyyaml --with pillow python3)
else
  echo "fork-verify: needs python3 with PyYAML and Pillow, or uv" >&2
  exit 2
fi
exec "${PY[@]}" "$HERE/fork_verify.py" "$@"

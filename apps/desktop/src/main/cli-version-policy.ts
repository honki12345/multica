// Fork builds must never spawn their daemon from an official `multica` CLI:
// the bundled CLI, a managed copy in userData, or one found on PATH may each
// be an upstream release, and an upstream daemon lacks the fork's changes.
// A fork version always carries the `-hoon.N` suffix (FORK.md "Version
// format"); upstream releases never do.
const FORK_VERSION = /^v?\d+\.\d+\.\d+-hoon\.\d+(?:[-+].*)?$/;

export function isForkCliVersion(version: string): boolean {
  return FORK_VERSION.test(version.trim());
}

// Dev builds (`pnpm dev:desktop`) keep accepting any CLI so contributors can
// run against whatever is installed.
export function acceptsCliVersion(version: string, isPackaged: boolean): boolean {
  return !isPackaged || isForkCliVersion(version);
}

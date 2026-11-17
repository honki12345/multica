#!/usr/bin/env bash
# License obligations check for the honki12345/multica fork (see FORK.md).
#
#   scripts/hoon/license-check.sh [--head <ref>] [--tag-prefix <refs/...>] [--base <tag>]
#
# Upstream release tags are read from <tag-prefix> (default refs/upstream-tags/,
# fill it with: git fetch --no-tags https://github.com/multica-ai/multica.git
# '+refs/tags/v*:refs/upstream-tags/v*'). The base tag is the newest upstream
# vX.Y.Z tag merged into <head>; it is what the fork's tree derives from.
#
# Failures (exit 1):
#   a. LICENSE differs from the base tag (byte for byte).
#   b. NOTICE dropped or changed a line of the base tag's NOTICE.
#   c. An upstream file changed or deleted since the base tag has no
#      "Modified by honki12345" notice in its first 30 lines and is not listed
#      under "Modified files without an inline notice" in FORK.md.
# Warnings (exit 0):
#   - The newest upstream tag ships a different LICENSE than the base tag.
#   - d. In UI areas, a logo/brand asset changed or was deleted, or a line
#     mentioning "Multica" disappeared.
set -uo pipefail

HEAD_REF=HEAD
PREFIX=refs/upstream-tags/
BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --head) HEAD_REF="$2"; shift 2 ;;
    --tag-prefix) PREFIX="${2%/}/"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    *) echo "usage: $0 [--head <ref>] [--tag-prefix <refs/...>] [--base <tag>]" >&2; exit 2 ;;
  esac
done

MARK='Modified by honki12345'
MARK_LINES=30
UI_DIRS='^(apps/web|apps/desktop|apps/mobile|packages/views|packages/ui)/'
BRAND_NAME='(logo|brand|favicon|wordmark|multica)'
IMAGE_EXT='\.(svg|png|ico|icns|jpe?g|webp|gif)$'
EXEMPT_HEADING='## Modified files without an inline notice'

errors=0
warnings=0
summary=""
error() { echo "::error${2:+ file=$2}::$1"; summary+="- ❌ $1"$'\n'; errors=$((errors + 1)); }
warn() { echo "::warning${2:+ file=$2}::$1"; summary+="- ⚠️ $1"$'\n'; warnings=$((warnings + 1)); }
finish() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "## Fork license check (base \`${BASE:-?}\`)"
      [ -n "$summary" ] && printf '%s' "$summary" || echo "- ✅ all checks passed"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  echo "license-check: base=${BASE:-?} latest=${LATEST:-?} errors=$errors warnings=$warnings"
  [ "$errors" -eq 0 ]
  exit $?
}

git rev-parse -q --verify "$HEAD_REF^{commit}" >/dev/null || { error "head ref $HEAD_REF not found"; finish; }
tags="$(git for-each-ref --sort=-v:refname --format='%(refname)' "$PREFIX" |
  sed "s#^${PREFIX}##" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$')"
[ -n "$tags" ] || { error "no upstream release tags under $PREFIX"; finish; }
LATEST="$(printf '%s\n' "$tags" | head -1)"
if [ -z "$BASE" ]; then
  for t in $tags; do
    if git merge-base --is-ancestor "$PREFIX$t" "$HEAD_REF" 2>/dev/null; then BASE="$t"; break; fi
  done
  [ -n "$BASE" ] || { error "no upstream release tag is merged into $HEAD_REF"; finish; }
fi
base_ref="$PREFIX$BASE"
git rev-parse -q --verify "$base_ref^{commit}" >/dev/null || { error "base tag $BASE not found under $PREFIX"; finish; }

blob() { git rev-parse -q --verify "$1:$2" 2>/dev/null; }

# a. LICENSE
if [ "$(blob "$base_ref" LICENSE)" != "$(blob "$HEAD_REF" LICENSE)" ] || [ -z "$(blob "$HEAD_REF" LICENSE)" ]; then
  error "LICENSE differs from upstream $BASE (must be kept byte for byte)" LICENSE
fi
if [ "$LATEST" != "$BASE" ] && [ "$(blob "$PREFIX$LATEST" LICENSE)" != "$(blob "$base_ref" LICENSE)" ]; then
  warn "upstream $LATEST changed LICENSE; take it over when merging $LATEST" LICENSE
fi

# b. NOTICE keeps every upstream line (only additions allowed).
if [ -z "$(blob "$HEAD_REF" NOTICE)" ]; then
  error "NOTICE is missing" NOTICE
elif [ -n "$(blob "$base_ref" NOTICE)" ]; then
  dropped="$(diff -a <(git show "$base_ref:NOTICE") <(git show "$HEAD_REF:NOTICE") | grep -c '^<' || true)"
  [ "$dropped" = 0 ] || error "NOTICE dropped or changed $dropped upstream line(s)" NOTICE
fi

# c. Modification notices.
exempt="$(git show "$HEAD_REF:FORK.md" 2>/dev/null | awk -v h="$EXEMPT_HEADING" '
  $0 == h { on = 1; next }
  on && /^## / { on = 0 }
  on && /^\| *`/ { split($0, p, "`"); print p[2] }')"
while IFS=$'\t' read -r st path; do
  [ -n "$path" ] || continue
  case "$path" in LICENSE|NOTICE|FORK.md) continue ;; esac
  grep -qxF -- "$path" <<<"$exempt" && continue
  if [ "$st" = D ]; then
    error "upstream file deleted but not listed in FORK.md: $path"
  # Capture first: with pipefail, grep -q exiting early would SIGPIPE git show.
  elif ! grep -aqF "$MARK" <<<"$(git show "$HEAD_REF:$path" 2>/dev/null | sed -n "1,${MARK_LINES}p")"; then
    error "modified upstream file has no '$MARK' notice in its first $MARK_LINES lines and is not listed in FORK.md: $path" "$path"
  fi
done < <(git -c core.quotePath=false diff --name-status --no-renames --diff-filter=MDT "$base_ref" "$HEAD_REF")

# d. UI branding (warnings only). Code comments are not displayed, so skip them.
brand_lines() {
  grep -aF Multica | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -avE '^(//|/\*|\*|#)' || true
}
while IFS=$'\t' read -r st path; do
  [ -n "$path" ] || continue
  grep -qE "$UI_DIRS" <<<"$path" || continue
  name="${path##*/}"
  if grep -qiE "$BRAND_NAME|$IMAGE_EXT" <<<"$name"; then
    if [ "$st" = D ]; then warn "UI logo/brand asset deleted: $path"; else warn "UI logo/brand asset changed: $path" "$path"; fi
    continue
  fi
  [ "$st" = D ] && new="" || new="$(git show "$HEAD_REF:$path" 2>/dev/null | brand_lines)"
  lost=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qxF -- "$line" <<<"$new" || lost=$((lost + 1))
  done < <(git show "$base_ref:$path" 2>/dev/null | brand_lines)
  [ "$lost" = 0 ] || warn "UI file lost $lost line(s) mentioning Multica; keep the name/attribution: $path" "$path"
done < <(git -c core.quotePath=false diff --name-status --no-renames --diff-filter=MDT "$base_ref" "$HEAD_REF")

finish

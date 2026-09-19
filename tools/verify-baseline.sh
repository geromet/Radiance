#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${VERIFY_OUT:-$ROOT/build/verification}"
MODE="${1:-boundary}"
FORK_BASE="3c1a137e76a02b7431713ab513352d8298aaf44f"
UPSTREAM_SOURCE="414d8e330a2fc6cb1e8630cc95f2302b2b97a0e8"
MCVR_FORK_BASE="69c87af5c88b6f2773a483a1c21d139ceddce78e"
MCVR_UPSTREAM_SOURCE="9905c81b1999f5845bf66d13501d371c16adf561"
MCVR_ROOT="${MCVR_ROOT:-$ROOT/../MCVR}"
NETWORK_CLOSED=false
mkdir -p "$OUT"

fail() { echo "verification error: $*" >&2; exit 1; }
sha() { git -C "$1" rev-parse --verify HEAD; }
version_line() { "$@" 2>&1 | head -n 1 | tr -d '\r'; }
require_commit() { git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null || fail "missing commit object $2 in $1"; }
require_ancestor() { git -C "$1" merge-base --is-ancestor "$2" "$3" || fail "$2 is not an ancestor of $3 in $1"; }
require_clean_tree() {
  local repo="$1" label="$2"
  git -C "$repo" diff --quiet --ignore-submodules=none -- || fail "$label has unstaged tracked changes"
  git -C "$repo" diff --cached --quiet --ignore-submodules=none -- || fail "$label has staged tracked changes"
  [[ -z "$(git -C "$repo" ls-files --others --exclude-standard)" ]] || fail "$label has untracked files"
}

RADIANCE_HEAD="$(sha "$ROOT")"
[[ "$RADIANCE_HEAD" =~ ^[0-9a-f]{40}$ ]] || fail "invalid Radiance HEAD"
require_commit "$ROOT" "$FORK_BASE"
require_commit "$ROOT" "$UPSTREAM_SOURCE"
require_ancestor "$ROOT" "$UPSTREAM_SOURCE" "$FORK_BASE"
require_ancestor "$ROOT" "$FORK_BASE" "$RADIANCE_HEAD"
require_clean_tree "$ROOT" "Radiance"

git -C "$MCVR_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "MCVR_ROOT is not a Git checkout: $MCVR_ROOT"
MCVR_HEAD="$(sha "$MCVR_ROOT")"
[[ "$MCVR_HEAD" =~ ^[0-9a-f]{40}$ ]] || fail "invalid MCVR HEAD"
require_commit "$MCVR_ROOT" "$MCVR_FORK_BASE"
require_commit "$MCVR_ROOT" "$MCVR_UPSTREAM_SOURCE"
require_ancestor "$MCVR_ROOT" "$MCVR_UPSTREAM_SOURCE" "$MCVR_FORK_BASE"
[[ "$MCVR_HEAD" == "$MCVR_FORK_BASE" ]] || fail "MCVR HEAD $MCVR_HEAD does not match intended fork basis $MCVR_FORK_BASE"
require_clean_tree "$MCVR_ROOT" "MCVR"

verify_boundary() {
  local verify_root="$1"
  test -x "$verify_root/gradlew" || return 1
  grep -q 'gradle-8\.14\.1-' "$verify_root/gradle/wrapper/gradle-wrapper.properties" || return 1
  grep -Eq 'JavaVersion\.toVersion\(targetJavaVersion\)|JavaLanguageVersion\.of\((21|targetJavaVersion)\)' "$verify_root/build.gradle" || return 1
  grep -q 'src/main/native/include' "$verify_root/build.gradle" || return 1
}

case "$MODE" in
  manifest)
    ;;
  boundary)
    verify_boundary "$ROOT" || fail "boundary verification failed"
    ;;
  boundary-negative)
    negative_root="$(mktemp -d "$OUT/boundary-negative.XXXXXX")"
    trap 'rm -rf "$negative_root"' EXIT
    mkdir -p "$negative_root/gradle/wrapper"
    cp "$ROOT/gradlew" "$negative_root/gradlew"
    cp "$ROOT/build.gradle" "$negative_root/build.gradle"
    cp "$ROOT/gradle/wrapper/gradle-wrapper.properties" "$negative_root/gradle/wrapper/gradle-wrapper.properties"
    sed -i 's/gradle-8\.14\.1-/gradle-0.0.0-/' "$negative_root/gradle/wrapper/gradle-wrapper.properties"
    cmp -s "$ROOT/gradle/wrapper/gradle-wrapper.properties" "$negative_root/gradle/wrapper/gradle-wrapper.properties" && fail "negative control did not corrupt the disposable canonical wrapper input"
    if verify_boundary "$negative_root"; then
      fail "negative control unexpectedly accepted corrupted canonical boundary input"
    fi
    echo 'negative control rejected corrupted canonical input under unchanged boundary contract as expected'
    ;;
  *)
    echo "usage: $0 {manifest|boundary|boundary-negative}" >&2
    exit 2
    ;;
esac

cat > "$OUT/input-manifest.json" <<EOF
{
  "schema": 3,
  "radiance": {
    "fork_base": "$FORK_BASE",
    "upstream_source": "$UPSTREAM_SOURCE",
    "verification_head": "$RADIANCE_HEAD",
    "worktree_clean": true
  },
  "mcvr": {
    "fork_base": "$MCVR_FORK_BASE",
    "upstream_source": "$MCVR_UPSTREAM_SOURCE",
    "verification_head": "$MCVR_HEAD",
    "worktree_clean": true
  },
  "environment": {
    "java": "$(version_line java -version | sed 's/"/\\"/g')",
    "gradle_wrapper": "$(grep '^distributionUrl=' "$ROOT/gradle/wrapper/gradle-wrapper.properties" | cut -d= -f2- | sed 's/\\/\\\\/g; s/"/\\"/g')",
    "kernel": "$(uname -sr | sed 's/"/\\"/g')",
    "os": "$(uname -sm | sed 's/"/\\"/g')",
    "locale": "${LC_ALL:-${LANG:-unknown}}",
    "timezone": "${TZ:-unknown}",
    "network_closed": $NETWORK_CLOSED
  }
}
EOF

sha256sum "$OUT/input-manifest.json" > "$OUT/input-manifest.sha256"
echo "verification mode=$MODE head=$RADIANCE_HEAD mcvr=$MCVR_HEAD network_closed=$NETWORK_CLOSED"

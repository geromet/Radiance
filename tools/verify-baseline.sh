#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${VERIFY_OUT:-$ROOT/build/verification}"
MODE="${1:-boundary}"
FORK_BASE="3c1a137e76a02b7431713ab513352d8298aaf44f"
UPSTREAM_SOURCE="414d8e330a2fc6cb1e8630cc95f2302b2b97a0e8"
MCVR_ROOT="${MCVR_ROOT:-$ROOT/../MCVR}"
NETWORK_CLOSED="${NETWORK_CLOSED:-false}"
mkdir -p "$OUT"

fail() { echo "verification error: $*" >&2; exit 1; }
sha() { git -C "$1" rev-parse --verify HEAD; }
version_line() { "$@" 2>&1 | head -n 1 | tr -d '\r'; }
require_commit() { git -C "$ROOT" cat-file -e "$1^{commit}" 2>/dev/null || fail "missing commit object $1"; }
require_ancestor() { git -C "$ROOT" merge-base --is-ancestor "$1" "$2" || fail "$1 is not an ancestor of $2"; }

RADIANCE_HEAD="$(sha "$ROOT")"
[[ "$RADIANCE_HEAD" =~ ^[0-9a-f]{40}$ ]] || fail "invalid Radiance HEAD"
require_commit "$FORK_BASE"
require_commit "$UPSTREAM_SOURCE"
require_ancestor "$UPSTREAM_SOURCE" "$FORK_BASE"
require_ancestor "$FORK_BASE" "$RADIANCE_HEAD"

git -C "$MCVR_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "MCVR_ROOT is not a Git checkout: $MCVR_ROOT"
MCVR_HEAD="$(sha "$MCVR_ROOT")"
[[ "$MCVR_HEAD" =~ ^[0-9a-f]{40}$ ]] || fail "invalid MCVR HEAD"

verify_boundary() {
  local expected_wrapper="$1"
  test -x "$ROOT/gradlew" || return 1
  grep -q "gradle-${expected_wrapper}-" "$ROOT/gradle/wrapper/gradle-wrapper.properties" || return 1
  grep -q 'JavaLanguageVersion.of(21)' "$ROOT/build.gradle" || return 1
  grep -q 'src/main/native/include' "$ROOT/build.gradle" || return 1
}

case "$MODE" in
  manifest)
    ;;
  boundary)
    verify_boundary '8\.14\.1' || fail "boundary verification failed"
    ;;
  boundary-negative)
    # Exercise the same positive verifier with one controlled-invalid input.
    if verify_boundary '0\.0\.0'; then
      fail "negative control unexpectedly satisfied the positive verifier"
    fi
    echo 'negative control rejected by positive verifier as expected'
    ;;
  *)
    echo "usage: $0 {manifest|boundary|boundary-negative}" >&2
    exit 2
    ;;
esac

cat > "$OUT/input-manifest.json" <<EOF
{
  "schema": 2,
  "radiance": {
    "fork_base": "$FORK_BASE",
    "upstream_source": "$UPSTREAM_SOURCE",
    "verification_head": "$RADIANCE_HEAD"
  },
  "mcvr": { "head": "$MCVR_HEAD" },
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
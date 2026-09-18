#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${VERIFY_OUT:-$ROOT/build/verification}"
MODE="${1:-boundary}"
mkdir -p "$OUT"

sha() { git -C "$1" rev-parse HEAD; }
version_line() { "$@" 2>&1 | head -n 1 | tr -d '\r'; }

RADIANCE_HEAD="$(sha "$ROOT")"
FORK_BASE="${RADIANCE_FORK_BASE:-3c1a137e76a02b7431713ab513352d8298aaf44f}"
UPSTREAM_SOURCE="${RADIANCE_UPSTREAM_SOURCE:-414d8e330a2fc6cb1e8630cc95f2302b2b97a0e8}"
MCVR_HEAD="${MCVR_HEAD:-unknown}"
NETWORK_CLOSED="${NETWORK_CLOSED:-false}"

cat > "$OUT/input-manifest.json" <<EOF
{
  "schema": 1,
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

case "$MODE" in
  manifest)
    ;;
  boundary)
    test -x "$ROOT/gradlew"
    grep -q 'gradle-8\.14\.1-' "$ROOT/gradle/wrapper/gradle-wrapper.properties"
    grep -q 'JavaLanguageVersion.of(21)' "$ROOT/build.gradle"
    grep -q 'src/main/native/include' "$ROOT/build.gradle"
    ;;
  boundary-negative)
    # Deliberate negative control: the impossible wrapper version must fail.
    if grep -q 'gradle-0\.0\.0-' "$ROOT/gradle/wrapper/gradle-wrapper.properties"; then
      echo 'negative control unexpectedly passed' >&2
      exit 1
    fi
    echo 'negative control failed as expected'
    ;;
  *)
    echo "usage: $0 {manifest|boundary|boundary-negative}" >&2
    exit 2
    ;;
esac

sha256sum "$OUT/input-manifest.json" > "$OUT/input-manifest.sha256"
echo "verification mode=$MODE head=$RADIANCE_HEAD network_closed=$NETWORK_CLOSED"
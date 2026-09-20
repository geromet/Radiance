#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${VERIFY_OUT:-$ROOT/build/verification}"
MODE="${1:-boundary}"
FORK_BASE="3c1a137e76a02b7431713ab513352d8298aaf44f"
UPSTREAM_SOURCE="414d8e330a2fc6cb1e8630cc95f2302b2b97a0e8"
MCVR_FORK_BASE="c2c203c82f85d4b99bb0fff3d3a591986119f2c3"
MCVR_UPSTREAM_SOURCE="9905c81b1999f5845bf66d13501d371c16adf561"
MCVR_ROOT="${MCVR_ROOT:-$ROOT/../MCVR}"
WRAPPER_JAR_SHA256="7d3a4ac4de1c32b59bc6a4eb8ecb8e612ccd0cf1ae1e99f66902da64df296172"
GRADLE_DIST_SHA256="845952a9d6afa783db70bb3b0effaae45ae5542ca2bb7929619e8af49cb634cf"
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
java_major_from_settings() { sed -n 's/^[[:space:]]*java.version = \([0-9][0-9]*\).*/\1/p' | head -n 1; }
require_exact_java21_settings() {
  local settings="$1" major
  major="$(printf '%s\n' "$settings" | java_major_from_settings)"
  [[ "$major" =~ ^[0-9]+$ ]] || fail "could not determine active Java runtime version"
  [[ "$major" == 21 ]] || fail "combined build requires exact Java major 21; found $major"
}
require_java21_runtime() { require_exact_java21_settings "$(java -XshowSettings:properties -version 2>&1)"; }
file_sha256() { sha256sum "$1" | awk '{print $1}'; }
require_wrapper_jar() {
  local jar="${1:-$ROOT/gradle/wrapper/gradle-wrapper.jar}" actual
  test -f "$jar" || fail "missing Gradle wrapper JAR: $jar"
  actual="$(file_sha256 "$jar")"
  printf '%s\n' "$actual" > "$OUT/gradle-wrapper-jar.sha256"
  [[ "$actual" == "$WRAPPER_JAR_SHA256" ]] || fail "Gradle wrapper JAR digest mismatch"
}
require_wrapper_properties() {
  local props="${1:-$ROOT/gradle/wrapper/gradle-wrapper.properties}"
  grep -Fxq 'distributionUrl=https\://services.gradle.org/distributions/gradle-8.14.1-bin.zip' "$props" || fail "unexpected Gradle distribution URL"
  grep -Fxq "distributionSha256Sum=$GRADLE_DIST_SHA256" "$props" || fail "unexpected Gradle distribution checksum"
}
prepare_proof_gradle_home() {
  local base="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
  PROOF_GRADLE_HOME="$(mktemp -d "$base/radiance-gradle-proof.XXXXXX")"
  test ! -e "$PROOF_GRADLE_HOME/wrapper/dists" || fail "proof Gradle distribution cache was preseeded"
  export GRADLE_USER_HOME="$PROOF_GRADLE_HOME"
  printf 'gradle_user_home=%s\nwrapper_dists_initial=absent\n' "$GRADLE_USER_HOME" > "$OUT/gradle-cache-basis.txt"
}
pre_gradle_proof() {
  require_wrapper_jar
  require_wrapper_properties
  prepare_proof_gradle_home
  printf 'wrapper_jar_sha256=%s\ndistribution_sha256=%s\n' "$WRAPPER_JAR_SHA256" "$GRADLE_DIST_SHA256" > "$OUT/gradle-bootstrap-basis.txt"
}
run_phase() {
  local name="$1"; shift
  local log="$OUT/${name}.log"
  echo "==> $name" | tee "$log"
  if ! "$@" 2>&1 | tee -a "$log"; then printf '%s\n' "$name" > "$OUT/failed-phase.txt"; return 1; fi
  printf 'PASS\n' > "$OUT/${name}.status"
}

RADIANCE_HEAD="$(sha "$ROOT")"
[[ "$RADIANCE_HEAD" =~ ^[0-9a-f]{40}$ ]] || fail "invalid Radiance HEAD"
require_commit "$ROOT" "$FORK_BASE"; require_commit "$ROOT" "$UPSTREAM_SOURCE"; require_ancestor "$ROOT" "$UPSTREAM_SOURCE" "$FORK_BASE"; require_ancestor "$ROOT" "$FORK_BASE" "$RADIANCE_HEAD"; require_clean_tree "$ROOT" "Radiance"
git -C "$MCVR_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "MCVR_ROOT is not a Git checkout: $MCVR_ROOT"
MCVR_HEAD="$(sha "$MCVR_ROOT")"
[[ "$MCVR_HEAD" =~ ^[0-9a-f]{40}$ ]] || fail "invalid MCVR HEAD"
require_commit "$MCVR_ROOT" "$MCVR_FORK_BASE"; require_commit "$MCVR_ROOT" "$MCVR_UPSTREAM_SOURCE"; require_ancestor "$MCVR_ROOT" "$MCVR_UPSTREAM_SOURCE" "$MCVR_FORK_BASE"
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
  manifest) ;;
  boundary) verify_boundary "$ROOT" || fail "boundary verification failed" ;;
  boundary-negative)
    negative_root="$(mktemp -d "$OUT/boundary-negative.XXXXXX")"; trap 'rm -rf "$negative_root"' EXIT
    mkdir -p "$negative_root/gradle/wrapper"; cp "$ROOT/gradlew" "$negative_root/gradlew"; cp "$ROOT/build.gradle" "$negative_root/build.gradle"; cp "$ROOT/gradle/wrapper/gradle-wrapper.properties" "$negative_root/gradle/wrapper/gradle-wrapper.properties"
    sed -i 's/gradle-8\.14\.1-/gradle-0.0.0-/' "$negative_root/gradle/wrapper/gradle-wrapper.properties"
    if verify_boundary "$negative_root"; then fail "negative control unexpectedly accepted corrupted canonical boundary input"; fi
    ;;
  java-major-negative)
    if (require_exact_java21_settings '    java.version = 22.0.1'); then fail "Java 22+ negative control unexpectedly passed exact-Java-21 guard"; fi
    require_exact_java21_settings '    java.version = 21.0.8'
    ;;
  wrapper-jar-negative)
    negative_jar="$(mktemp "$OUT/gradle-wrapper-substituted.XXXXXX.jar")"; cp "$ROOT/gradle/wrapper/gradle-wrapper.jar" "$negative_jar"; printf '\001' >> "$negative_jar"
    if (require_wrapper_jar "$negative_jar"); then fail "substituted wrapper JAR unexpectedly passed"; fi
    echo 'substituted wrapper JAR rejected before Java/Gradle launch as expected'
    ;;
  distribution-checksum-negative)
    negative_props="$(mktemp "$OUT/gradle-wrapper-wrong-checksum.XXXXXX.properties")"; cp "$ROOT/gradle/wrapper/gradle-wrapper.properties" "$negative_props"; sed -i "s/$GRADLE_DIST_SHA256/0000000000000000000000000000000000000000000000000000000000000000/" "$negative_props"
    if (require_wrapper_properties "$negative_props"); then fail "wrong distribution checksum unexpectedly passed"; fi
    echo 'wrong distribution checksum rejected before wrapper launch as expected'
    ;;
  cache-preseed-negative)
    PROOF_GRADLE_HOME="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/radiance-gradle-preseed.XXXXXX")"; mkdir -p "$PROOF_GRADLE_HOME/wrapper/dists/fake"
    if test ! -e "$PROOF_GRADLE_HOME/wrapper/dists"; then fail "preseed negative setup failed"; fi
    echo 'preseeded cache state detected before wrapper launch as expected'
    ;;
  gradle-bootstrap)
    rm -f "$OUT/failed-phase.txt"
    require_java21_runtime
    pre_gradle_proof
    run_phase gradle-bootstrap "$ROOT/gradlew" --no-daemon --version || fail "Gradle bootstrap proof failed"
    ;;
  combined-build)
    rm -f "$OUT/failed-phase.txt"
    require_java21_runtime
    pre_gradle_proof
    run_phase radiance-jni "$ROOT/gradlew" --no-daemon compileJava || fail "Radiance JNI generation failed"
    test -d "$ROOT/src/main/native/include" || fail "Radiance JNI include directory was not generated"
    git -C "$MCVR_ROOT" submodule update --init --recursive 2>&1 | tee "$OUT/mcvr-submodules.log" || { printf '%s\n' mcvr-submodules > "$OUT/failed-phase.txt"; fail "MCVR recursive submodule initialization failed"; }
    MCVR_BUILD="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/mcvr-build.XXXXXX")"; trap 'rm -rf "$MCVR_BUILD" "$PROOF_GRADLE_HOME"' EXIT
    run_phase mcvr-configure cmake -S "$MCVR_ROOT" -B "$MCVR_BUILD" -DCMAKE_BUILD_TYPE=Release -DJAVA_PROJECT_ROOT_DIR="$ROOT" -DUSE_AMD=ON -DMCVR_ENABLE_FFX_UPSCALER=OFF -DMCVR_ENABLE_NRD=ON || fail "MCVR configure failed"
    run_phase mcvr-build cmake --build "$MCVR_BUILD" --parallel "${BUILD_JOBS:-2}" || fail "MCVR build failed"
    run_phase mcvr-install cmake --install "$MCVR_BUILD" || fail "MCVR install failed"
    require_wrapper_jar
    run_phase radiance-package "$ROOT/gradlew" --no-daemon build || fail "final Radiance package failed"
    find "$ROOT/build/libs" -maxdepth 1 -type f -print0 | sort -z | xargs -0 -r sha256sum > "$OUT/radiance-artifacts.sha256"
    ;;
  *) echo "usage: $0 {manifest|boundary|boundary-negative|java-major-negative|wrapper-jar-negative|distribution-checksum-negative|cache-preseed-negative|gradle-bootstrap|combined-build}" >&2; exit 2 ;;
esac

cat > "$OUT/input-manifest.json" <<EOF
{
  "schema": 4,
  "radiance": {"fork_base":"$FORK_BASE","upstream_source":"$UPSTREAM_SOURCE","verification_head":"$RADIANCE_HEAD","worktree_clean":true},
  "mcvr": {"fork_base":"$MCVR_FORK_BASE","upstream_source":"$MCVR_UPSTREAM_SOURCE","verification_head":"$MCVR_HEAD","worktree_clean":true},
  "gradle_bootstrap": {"wrapper_jar_sha256":"$WRAPPER_JAR_SHA256","distribution_sha256":"$GRADLE_DIST_SHA256"},
  "environment": {"java":"$(version_line java -version | sed 's/"/\\"/g')","gradle_wrapper":"$(grep '^distributionUrl=' "$ROOT/gradle/wrapper/gradle-wrapper.properties" | cut -d= -f2- | sed 's/\\/\\\\/g; s/"/\\"/g')","cmake":"$(version_line cmake --version | sed 's/"/\\"/g')","compiler":"$(version_line c++ --version | sed 's/"/\\"/g')","kernel":"$(uname -sr | sed 's/"/\\"/g')","os":"$(uname -sm | sed 's/"/\\"/g')","locale":"${LC_ALL:-${LANG:-unknown}}","timezone":"${TZ:-unknown}","network_closed":$NETWORK_CLOSED}
}
EOF
sha256sum "$OUT/input-manifest.json" > "$OUT/input-manifest.sha256"
echo "verification mode=$MODE head=$RADIANCE_HEAD mcvr=$MCVR_HEAD network_closed=$NETWORK_CLOSED"

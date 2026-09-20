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
file_sha256() { sha256sum "$1" | awk '{print $1}'; }
require_commit() { git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null || fail "missing commit object $2 in $1"; }
require_ancestor() { git -C "$1" merge-base --is-ancestor "$2" "$3" || fail "$2 is not an ancestor of $3 in $1"; }
require_clean_tree() { local r="$1" l="$2"; git -C "$r" diff --quiet --ignore-submodules=none -- || fail "$l has unstaged tracked changes"; git -C "$r" diff --cached --quiet --ignore-submodules=none -- || fail "$l has staged tracked changes"; [[ -z "$(git -C "$r" ls-files --others --exclude-standard)" ]] || fail "$l has untracked files"; }
java_major_from_settings() { sed -n 's/^[[:space:]]*java.version = \([0-9][0-9]*\).*/\1/p' | head -n 1; }
require_exact_java21_settings() { local s="$1" m; m="$(printf '%s\n' "$s" | java_major_from_settings)"; [[ "$m" =~ ^[0-9]+$ ]] || fail "could not determine active Java runtime version"; [[ "$m" == 21 ]] || fail "combined build requires exact Java major 21; found $m"; }
require_java21_runtime() { require_exact_java21_settings "$(java -XshowSettings:properties -version 2>&1)"; }

RADIANCE_HEAD="$(sha "$ROOT")"
MCVR_HEAD="$(sha "$MCVR_ROOT")"
[[ "$RADIANCE_HEAD" =~ ^[0-9a-f]{40}$ && "$MCVR_HEAD" =~ ^[0-9a-f]{40}$ ]] || fail "invalid repository head"
EFFECTIVE_INPUT_SHA256="${VERIFY_EFFECTIVE_INPUT_SHA256:-none}"
[[ "$EFFECTIVE_INPUT_SHA256" == none || "$EFFECTIVE_INPUT_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "invalid effective-input digest binding"

cat > "$OUT/attempt-basis.json" <<EOF
{"schema":5,"mode":"$MODE","radiance_head":"$RADIANCE_HEAD","mcvr_head":"$MCVR_HEAD","wrapper_expected_sha256":"$WRAPPER_JAR_SHA256","distribution_expected_sha256":"$GRADLE_DIST_SHA256","effective_input_sha256":"$EFFECTIVE_INPUT_SHA256"}
EOF
sha256sum "$OUT/attempt-basis.json" > "$OUT/attempt-basis.sha256"
printf 'mode=%s\nphase=preflight\noutcome=STARTED\n' "$MODE" > "$OUT/terminal-result.txt"
CURRENT_PHASE=preflight
finish() { local rc=$? outcome=PASS; [[ $rc -eq 0 ]] || outcome=FAIL; printf 'mode=%s\nphase=%s\noutcome=%s\nexit_code=%s\neffective_input_sha256=%s\n' "$MODE" "$CURRENT_PHASE" "$outcome" "$rc" "$EFFECTIVE_INPUT_SHA256" > "$OUT/terminal-result.txt"; }
trap finish EXIT

require_commit "$ROOT" "$FORK_BASE"; require_commit "$ROOT" "$UPSTREAM_SOURCE"; require_ancestor "$ROOT" "$UPSTREAM_SOURCE" "$FORK_BASE"; require_ancestor "$ROOT" "$FORK_BASE" "$RADIANCE_HEAD"
git -C "$MCVR_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "MCVR_ROOT is not a Git checkout"
require_commit "$MCVR_ROOT" "$MCVR_FORK_BASE"; require_commit "$MCVR_ROOT" "$MCVR_UPSTREAM_SOURCE"; require_ancestor "$MCVR_ROOT" "$MCVR_UPSTREAM_SOURCE" "$MCVR_FORK_BASE"
[[ "$MCVR_HEAD" == "$MCVR_FORK_BASE" ]] || fail "MCVR HEAD does not match intended fork basis"
require_clean_tree "$ROOT" Radiance; require_clean_tree "$MCVR_ROOT" MCVR

WRAPPER_JAR="${VERIFY_WRAPPER_JAR:-$ROOT/gradle/wrapper/gradle-wrapper.jar}"
WRAPPER_PROPERTIES="${VERIFY_WRAPPER_PROPERTIES:-$ROOT/gradle/wrapper/gradle-wrapper.properties}"
require_wrapper_jar() { CURRENT_PHASE=wrapper-jar-attestation; local actual; test -f "$WRAPPER_JAR" || fail "missing Gradle wrapper JAR"; actual="$(file_sha256 "$WRAPPER_JAR")"; printf '%s\n' "$actual" > "$OUT/gradle-wrapper-jar.sha256"; [[ "$actual" == "$WRAPPER_JAR_SHA256" || "${VERIFY_BYPASS_WRAPPER_GUARD:-0}" == 1 ]] || fail "Gradle wrapper JAR digest mismatch"; }
require_wrapper_properties() { CURRENT_PHASE=distribution-declaration-attestation; grep -Fxq 'distributionUrl=https\://services.gradle.org/distributions/gradle-8.14.1-bin.zip' "$WRAPPER_PROPERTIES" || fail "unexpected Gradle distribution URL"; grep -Fxq "distributionSha256Sum=$GRADLE_DIST_SHA256" "$WRAPPER_PROPERTIES" || [[ "${VERIFY_BYPASS_DISTRIBUTION_GUARD:-0}" == 1 ]] || fail "unexpected Gradle distribution checksum"; }
prepare_proof_gradle_home() { CURRENT_PHASE=proof-cache-confinement; local base="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"; if [[ -n "${VERIFY_PROOF_GRADLE_HOME:-}" ]]; then PROOF_GRADLE_HOME="$VERIFY_PROOF_GRADLE_HOME"; else PROOF_GRADLE_HOME="$(mktemp -d "$base/radiance-gradle-proof.XXXXXX")"; fi; if [[ "${VERIFY_BYPASS_CACHE_GUARD:-0}" != 1 ]]; then test ! -e "$PROOF_GRADLE_HOME/wrapper/dists" || fail "proof Gradle distribution cache was preseeded"; case "$PROOF_GRADLE_HOME" in "$base"/radiance-gradle-proof.*) ;; *) fail "proof Gradle cache escaped attempt-owned root";; esac; fi; export GRADLE_USER_HOME="$PROOF_GRADLE_HOME"; printf 'gradle_user_home=%s\nwrapper_dists_initial=absent\n' "$GRADLE_USER_HOME" > "$OUT/gradle-cache-basis.txt"; }
pre_gradle_proof() { require_wrapper_jar; require_wrapper_properties; prepare_proof_gradle_home; printf 'wrapper_jar_sha256=%s\ndistribution_sha256=%s\n' "$WRAPPER_JAR_SHA256" "$GRADLE_DIST_SHA256" > "$OUT/gradle-bootstrap-basis.txt"; }
prepare_effective_wrapper() { CURRENT_PHASE=effective-wrapper-materialization; EFFECTIVE_WRAPPER_DIR="$OUT/effective-wrapper"; rm -rf "$EFFECTIVE_WRAPPER_DIR"; mkdir -p "$EFFECTIVE_WRAPPER_DIR"; cp "$WRAPPER_JAR" "$EFFECTIVE_WRAPPER_DIR/gradle-wrapper.jar"; cp "$WRAPPER_PROPERTIES" "$EFFECTIVE_WRAPPER_DIR/gradle-wrapper.properties"; printf 'wrapper_jar_sha256=%s\nwrapper_properties_sha256=%s\n' "$(file_sha256 "$EFFECTIVE_WRAPPER_DIR/gradle-wrapper.jar")" "$(file_sha256 "$EFFECTIVE_WRAPPER_DIR/gradle-wrapper.properties")" > "$OUT/effective-wrapper-basis.txt"; }
run_effective_gradle() { prepare_effective_wrapper; java -classpath "$EFFECTIVE_WRAPPER_DIR/gradle-wrapper.jar" org.gradle.wrapper.GradleWrapperMain "$@"; }
run_phase() { local n="$1"; shift; CURRENT_PHASE="$n"; local log="$OUT/$n.log"; echo "==> $n" | tee "$log"; if ! "$@" 2>&1 | tee -a "$log"; then printf '%s\n' "$n" > "$OUT/failed-phase.txt"; return 1; fi; printf 'PASS\n' > "$OUT/$n.status"; }
verify_boundary() { local r="$1"; test -x "$r/gradlew" && grep -q 'gradle-8\.14\.1-' "$r/gradle/wrapper/gradle-wrapper.properties" && grep -Eq 'JavaVersion\.toVersion\(targetJavaVersion\)|JavaLanguageVersion\.of\((21|targetJavaVersion)\)' "$r/build.gradle" && grep -q 'src/main/native/include' "$r/build.gradle"; }

proof_negative() {
  local kind="$1"
  local child="$OUT/proof-negative-$kind"
  mkdir -p "$child"
  local jar="$ROOT/gradle/wrapper/gradle-wrapper.jar" props="$ROOT/gradle/wrapper/gradle-wrapper.properties" home=""
  case "$kind" in
    wrapper) jar="$(mktemp "$OUT/substituted.XXXXXX.jar")"; cp "$ROOT/gradle/wrapper/gradle-wrapper.jar" "$jar"; printf '\001' >> "$jar";;
    checksum) props="$(mktemp "$OUT/wrong-checksum.XXXXXX.properties")"; cp "$ROOT/gradle/wrapper/gradle-wrapper.properties" "$props"; sed -i "s/$GRADLE_DIST_SHA256/0000000000000000000000000000000000000000000000000000000000000000/" "$props";;
    preseed) home="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/radiance-gradle-proof.XXXXXX")"; mkdir -p "$home/wrapper/dists/fake";;
    escape) home="$(mktemp -d "${TMPDIR:-/tmp}/radiance-gradle-external.XXXXXX")";;
  esac
  set +e
  VERIFY_OUT="$child" VERIFY_WRAPPER_JAR="$jar" VERIFY_WRAPPER_PROPERTIES="$props" VERIFY_PROOF_GRADLE_HOME="$home" bash "$0" gradle-bootstrap
  local rc=$?; set -e
  [[ $rc -ne 0 ]] || fail "$kind proof negative unexpectedly passed"
  grep -Fxq 'outcome=FAIL' "$child/terminal-result.txt" || fail "$kind negative lacks terminal failure evidence"
  test -s "$child/attempt-basis.sha256" || fail "$kind negative lacks pre-effect attempt identity"
  case "$kind" in
    wrapper) VERIFY_OUT="$child/sensitivity" VERIFY_WRAPPER_JAR="$jar" VERIFY_BYPASS_WRAPPER_GUARD=1 bash "$0" manifest >/dev/null;;
    checksum) VERIFY_OUT="$child/sensitivity" VERIFY_WRAPPER_PROPERTIES="$props" VERIFY_BYPASS_DISTRIBUTION_GUARD=1 bash "$0" manifest >/dev/null;;
    preseed|escape) VERIFY_OUT="$child/sensitivity" VERIFY_PROOF_GRADLE_HOME="$home" VERIFY_BYPASS_CACHE_GUARD=1 bash "$0" manifest >/dev/null;;
  esac
  printf 'negative=%s\nrejection_exit=%s\nsensitivity=bypass-accepted\n' "$kind" "$rc" > "$child/oracle.txt"
}

case "$MODE" in
 manifest) ;;
 boundary) verify_boundary "$ROOT" || fail "boundary verification failed";;
 boundary-negative) n="$(mktemp -d "$OUT/boundary-negative.XXXXXX")"; mkdir -p "$n/gradle/wrapper"; cp "$ROOT/gradlew" "$n/gradlew"; cp "$ROOT/build.gradle" "$n/build.gradle"; cp "$ROOT/gradle/wrapper/gradle-wrapper.properties" "$n/gradle/wrapper/gradle-wrapper.properties"; sed -i 's/gradle-8\.14\.1-/gradle-0.0.0-/' "$n/gradle/wrapper/gradle-wrapper.properties"; if verify_boundary "$n"; then fail "negative boundary accepted"; fi;;
 java-major-negative) if (require_exact_java21_settings ' java.version = 22.0.1'); then fail "Java 22 negative passed"; fi; require_exact_java21_settings ' java.version = 21.0.8';;
 wrapper-jar-negative) proof_negative wrapper;;
 distribution-checksum-negative) proof_negative checksum;;
 cache-preseed-negative) proof_negative preseed;;
 cache-root-negative) proof_negative escape;;
 gradle-bootstrap) require_java21_runtime; pre_gradle_proof; run_phase gradle-bootstrap run_effective_gradle --no-daemon --version || fail "Gradle bootstrap proof failed";;
 combined-build)
   require_java21_runtime; pre_gradle_proof
   run_phase radiance-jni run_effective_gradle --no-daemon compileJava || fail "Radiance JNI generation failed"
   test -d "$ROOT/src/main/native/include" || fail "Radiance JNI include directory was not generated"
   CURRENT_PHASE=mcvr-submodules; git -C "$MCVR_ROOT" submodule update --init --recursive 2>&1 | tee "$OUT/mcvr-submodules.log" || fail "MCVR recursive submodule initialization failed"
   MCVR_BUILD="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/mcvr-build.XXXXXX")"
   run_phase mcvr-configure cmake -S "$MCVR_ROOT" -B "$MCVR_BUILD" -DCMAKE_BUILD_TYPE=Release -DJAVA_PROJECT_ROOT_DIR="$ROOT" -DUSE_AMD=ON -DMCVR_ENABLE_FFX_UPSCALER=OFF -DMCVR_ENABLE_NRD=ON || fail "MCVR configure failed"
   run_phase mcvr-build cmake --build "$MCVR_BUILD" --parallel "${BUILD_JOBS:-2}" || fail "MCVR build failed"
   run_phase mcvr-install cmake --install "$MCVR_BUILD" || fail "MCVR install failed"
   require_wrapper_jar; run_phase radiance-package run_effective_gradle --no-daemon build || fail "final Radiance package failed"
   find "$ROOT/build/libs" -maxdepth 1 -type f -print0 | sort -z | xargs -0 -r sha256sum > "$OUT/radiance-artifacts.sha256";;
 *) echo "usage: $0 {manifest|boundary|boundary-negative|java-major-negative|wrapper-jar-negative|distribution-checksum-negative|cache-preseed-negative|cache-root-negative|gradle-bootstrap|combined-build}" >&2; exit 2;;
esac

CURRENT_PHASE=terminal-evidence
cat > "$OUT/input-manifest.json" <<EOF
{"schema":5,"radiance":{"fork_base":"$FORK_BASE","upstream_source":"$UPSTREAM_SOURCE","verification_head":"$RADIANCE_HEAD"},"mcvr":{"fork_base":"$MCVR_FORK_BASE","upstream_source":"$MCVR_UPSTREAM_SOURCE","verification_head":"$MCVR_HEAD"},"gradle_bootstrap":{"wrapper_jar_sha256":"$WRAPPER_JAR_SHA256","distribution_sha256":"$GRADLE_DIST_SHA256"},"environment":{"java":"$(version_line java -version | sed 's/"/\\"/g')","network_closed":$NETWORK_CLOSED}}
EOF
sha256sum "$OUT/input-manifest.json" > "$OUT/input-manifest.sha256"
echo "verification mode=$MODE head=$RADIANCE_HEAD mcvr=$MCVR_HEAD network_closed=$NETWORK_CLOSED"

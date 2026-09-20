#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${VERIFY_OUT:-$ROOT/build/verification-spec5}"
VERIFY="$ROOT/tools/verify-baseline.sh"
mkdir -p "$OUT"

sha256_file() { sha256sum "$1" | awk '{print $1}'; }
fail() { echo "spec5 proof error: $*" >&2; exit 1; }

run_negative() {
  local kind="$1" expected_phase="$2"
  local child corrupt sensitivity
  child="$OUT/$kind"
  corrupt="$child/corrupt"
  sensitivity="$child/sensitivity"
  local jar="$ROOT/gradle/wrapper/gradle-wrapper.jar"
  local props="$ROOT/gradle/wrapper/gradle-wrapper.properties"
  local home=""
  mkdir -p "$corrupt" "$sensitivity"

  case "$kind" in
    wrapper)
      jar="$child/substituted-wrapper.jar"
      cp "$ROOT/gradle/wrapper/gradle-wrapper.jar" "$jar"
      printf '\001' >> "$jar"
      ;;
    checksum)
      props="$child/wrong-checksum.properties"
      cp "$ROOT/gradle/wrapper/gradle-wrapper.properties" "$props"
      sed -i 's/distributionSha256Sum=.*/distributionSha256Sum=0000000000000000000000000000000000000000000000000000000000000000/' "$props"
      ;;
    preseed)
      home="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/radiance-gradle-proof.XXXXXX")"
      mkdir -p "$home/wrapper/dists/fake"
      ;;
    escape)
      home="$(mktemp -d "${TMPDIR:-/tmp}/radiance-gradle-external.XXXXXX")"
      ;;
    *) fail "unknown negative $kind" ;;
  esac

  local wrapper_digest props_digest cache_state cache_root
  wrapper_digest="$(sha256_file "$jar")"
  props_digest="$(sha256_file "$props")"
  cache_root="${home:-auto-attempt-owned}"
  if [[ -n "$home" && -e "$home/wrapper/dists" ]]; then cache_state=preseeded; else cache_state=absent; fi
  cat > "$child/effective-input.json" <<EOF
{"schema":5,"negative":"$kind","wrapper_sha256":"$wrapper_digest","wrapper_properties_sha256":"$props_digest","proof_cache_root":"$cache_root","proof_cache_initial_state":"$cache_state","expected_failure_phase":"$expected_phase"}
EOF
  sha256sum "$child/effective-input.json" > "$child/effective-input.sha256"

  set +e
  VERIFY_OUT="$corrupt" VERIFY_WRAPPER_JAR="$jar" VERIFY_WRAPPER_PROPERTIES="$props" VERIFY_PROOF_GRADLE_HOME="$home" bash "$VERIFY" gradle-bootstrap
  local rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail "$kind corrupt-input proof unexpectedly passed"
  test -s "$corrupt/attempt-basis.sha256" || fail "$kind lacks pre-effect base identity"
  test -s "$corrupt/terminal-result.txt" || fail "$kind lacks terminal evidence"
  grep -Fxq "phase=$expected_phase" "$corrupt/terminal-result.txt" || fail "$kind rejected at wrong phase; expected $expected_phase"
  grep -Fxq 'outcome=FAIL' "$corrupt/terminal-result.txt" || fail "$kind lacks FAIL outcome"

  # Same proof-bearing path sensitivity: keep the corrupt input effective and bypass only
  # the selected repository guard. Sensitivity is proven only when the guarded bootstrap
  # completes successfully after crossing that guard. A different downstream failure must
  # not count as acceptance of the counterfactual.
  set +e
  case "$kind" in
    wrapper)
      VERIFY_OUT="$sensitivity" VERIFY_WRAPPER_JAR="$jar" VERIFY_BYPASS_WRAPPER_GUARD=1 bash "$VERIFY" gradle-bootstrap ;;
    checksum)
      VERIFY_OUT="$sensitivity" VERIFY_WRAPPER_PROPERTIES="$props" VERIFY_BYPASS_DISTRIBUTION_GUARD=1 bash "$VERIFY" gradle-bootstrap ;;
    preseed|escape)
      VERIFY_OUT="$sensitivity" VERIFY_PROOF_GRADLE_HOME="$home" VERIFY_BYPASS_CACHE_GUARD=1 bash "$VERIFY" gradle-bootstrap ;;
  esac
  local sensitivity_rc=$?
  set -e
  local sensitivity_phase=missing sensitivity_outcome=missing
  if [[ -f "$sensitivity/terminal-result.txt" ]]; then
    sensitivity_phase="$(sed -n 's/^phase=//p' "$sensitivity/terminal-result.txt" | tail -n1)"
    sensitivity_outcome="$(sed -n 's/^outcome=//p' "$sensitivity/terminal-result.txt" | tail -n1)"
  fi
  [[ $sensitivity_rc -eq 0 ]] || fail "$kind sensitivity did not complete the post-guard bootstrap; exit=$sensitivity_rc phase=$sensitivity_phase"
  [[ "$sensitivity_phase" == terminal-evidence ]] || fail "$kind sensitivity lacks successful terminal evidence; phase=$sensitivity_phase"
  [[ "$sensitivity_outcome" == PASS ]] || fail "$kind sensitivity lacks PASS terminal outcome; outcome=$sensitivity_outcome"

  printf 'negative=%s\nexpected_phase=%s\nrejection_exit=%s\nsensitivity_exit=%s\nsensitivity_phase=%s\nsensitivity_outcome=%s\npost_guard_boundary=gradle-bootstrap\nresult=PASS\n' \
    "$kind" "$expected_phase" "$rc" "$sensitivity_rc" "$sensitivity_phase" "$sensitivity_outcome" > "$child/oracle.txt"
}

run_masking_control() {
  local child="$OUT/earlier-failure-masking"
  mkdir -p "$child"
  set +e
  PATH=/nonexistent VERIFY_OUT="$child" bash "$VERIFY" gradle-bootstrap >/dev/null 2>&1
  local rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail "masking control unexpectedly passed"
  if [[ -f "$child/terminal-result.txt" ]] && grep -Eq '^phase=(wrapper-jar-attestation|distribution-declaration-attestation|proof-cache-confinement)$' "$child/terminal-result.txt"; then
    fail "earlier unrelated failure masqueraded as an integrity-guard rejection"
  fi
  printf 'result=PASS\nexit=%s\n' "$rc" > "$child/oracle.txt"
}

run_negative wrapper wrapper-jar-attestation
run_negative checksum distribution-declaration-attestation
run_negative preseed proof-cache-confinement
run_negative escape proof-cache-confinement
run_masking_control
printf 'spec5_gradle_proof=PASS\n' | tee "$OUT/result.txt"

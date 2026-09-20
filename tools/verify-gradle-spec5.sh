#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${VERIFY_OUT:-$ROOT/build/verification-spec5}"
VERIFY="$ROOT/tools/verify-baseline.sh"
mkdir -p "$OUT"

sha256_file() { sha256sum "$1" | awk '{print $1}'; }
fail() { echo "spec5 proof error: $*" >&2; exit 1; }

evidence_link_valid() {
  local evidence="$1" effective_input="$2" digest
  digest="$(sha256_file "$effective_input")"
  grep -Fq "\"effective_input_sha256\":\"$digest\"" "$evidence/attempt-basis.json" &&
    grep -Fxq "effective_input_sha256=$digest" "$evidence/terminal-result.txt"
}

assert_link() {
  local evidence="$1" effective_input="$2" label="$3"
  evidence_link_valid "$evidence" "$effective_input" || fail "$label retained evidence is not linked to the effective input bytes"
}

terminal_field() { sed -n "s/^$2=//p" "$1/terminal-result.txt" | tail -n1; }

write_effective_input() {
  local path="$1" kind="$2" wrapper_digest="$3" props_digest="$4" cache_role="$5" cache_state="$6" expected_phase="$7"
  cat > "$path" <<EOF
{"schema":5,"negative":"$kind","wrapper_sha256":"$wrapper_digest","wrapper_properties_sha256":"$props_digest","proof_cache_role":"$cache_role","proof_cache_initial_state":"$cache_state","expected_failure_phase":"$expected_phase"}
EOF
}

run_negative() {
  local kind="$1" expected_phase="$2"
  local child corrupt sensitivity
  child="$OUT/$kind"
  corrupt="$child/corrupt"
  sensitivity="$child/sensitivity"
  local jar="$ROOT/gradle/wrapper/gradle-wrapper.jar"
  local props="$ROOT/gradle/wrapper/gradle-wrapper.properties"
  local home=""
  local cache_role="attempt-owned-auto"
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
      cache_role="attempt-owned-preseeded"
      mkdir -p "$home/wrapper/dists/fake"
      ;;
    escape)
      home="$(mktemp -d "${TMPDIR:-/tmp}/radiance-gradle-external.XXXXXX")"
      cache_role="external-escape"
      ;;
    *) fail "unknown negative $kind" ;;
  esac

  local wrapper_digest props_digest cache_state effective_digest
  wrapper_digest="$(sha256_file "$jar")"
  props_digest="$(sha256_file "$props")"
  if [[ -n "$home" && -e "$home/wrapper/dists" ]]; then cache_state=preseeded; else cache_state=absent; fi
  write_effective_input "$child/effective-input.json" "$kind" "$wrapper_digest" "$props_digest" "$cache_role" "$cache_state" "$expected_phase"
  effective_digest="$(sha256_file "$child/effective-input.json")"
  printf '%s  %s\n' "$effective_digest" "$child/effective-input.json" > "$child/effective-input.sha256"
  # Concrete randomized paths are diagnostic confinement evidence only; they must not perturb semantic attempt identity.
  printf 'proof_cache_role=%s\nproof_cache_path=%s\n' "$cache_role" "${home:-auto-attempt-owned}" > "$child/cache-path.txt"

  if [[ "$kind" == preseed || "$kind" == escape ]]; then
    local replay_home replay_digest
    if [[ "$kind" == preseed ]]; then
      replay_home="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/radiance-gradle-proof.XXXXXX")"
      mkdir -p "$replay_home/wrapper/dists/fake"
    else
      replay_home="$(mktemp -d "${TMPDIR:-/tmp}/radiance-gradle-external.XXXXXX")"
    fi
    [[ "$replay_home" != "$home" ]] || fail "$kind stability control did not obtain a distinct concrete cache path"
    write_effective_input "$child/effective-input-replay.json" "$kind" "$wrapper_digest" "$props_digest" "$cache_role" "$cache_state" "$expected_phase"
    replay_digest="$(sha256_file "$child/effective-input-replay.json")"
    [[ "$replay_digest" == "$effective_digest" ]] || fail "$kind semantic cache identity changed across equivalent randomized paths"
    printf 'first_path=%s\nsecond_path=%s\nsemantic_digest=%s\nresult=PASS\n' "$home" "$replay_home" "$effective_digest" > "$child/cache-identity-stability.txt"
    rm -rf "$replay_home"
  fi

  set +e
  VERIFY_OUT="$corrupt" VERIFY_EFFECTIVE_INPUT_SHA256="$effective_digest" VERIFY_WRAPPER_JAR="$jar" VERIFY_WRAPPER_PROPERTIES="$props" VERIFY_PROOF_GRADLE_HOME="$home" bash "$VERIFY" gradle-bootstrap
  local rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail "$kind corrupt-input proof unexpectedly passed"
  test -s "$corrupt/attempt-basis.sha256" || fail "$kind lacks pre-effect base identity"
  test -s "$corrupt/terminal-result.txt" || fail "$kind lacks terminal evidence"
  assert_link "$corrupt" "$child/effective-input.json" "$kind corrupt"
  grep -Fxq "phase=$expected_phase" "$corrupt/terminal-result.txt" || fail "$kind rejected at wrong phase; expected $expected_phase"
  grep -Fxq 'outcome=FAIL' "$corrupt/terminal-result.txt" || fail "$kind lacks FAIL outcome"

  set +e
  case "$kind" in
    wrapper)
      VERIFY_OUT="$sensitivity" VERIFY_EFFECTIVE_INPUT_SHA256="$effective_digest" VERIFY_WRAPPER_JAR="$jar" VERIFY_BYPASS_WRAPPER_GUARD=1 bash "$VERIFY" gradle-bootstrap ;;
    checksum)
      VERIFY_OUT="$sensitivity" VERIFY_EFFECTIVE_INPUT_SHA256="$effective_digest" VERIFY_WRAPPER_PROPERTIES="$props" VERIFY_BYPASS_DISTRIBUTION_GUARD=1 bash "$VERIFY" gradle-bootstrap ;;
    preseed|escape)
      VERIFY_OUT="$sensitivity" VERIFY_EFFECTIVE_INPUT_SHA256="$effective_digest" VERIFY_PROOF_GRADLE_HOME="$home" VERIFY_BYPASS_CACHE_GUARD=1 bash "$VERIFY" gradle-bootstrap ;;
  esac
  local sensitivity_rc=$?
  set -e
  local sensitivity_phase=missing sensitivity_outcome=missing
  if [[ -f "$sensitivity/terminal-result.txt" ]]; then
    sensitivity_phase="$(terminal_field "$sensitivity" phase)"
    sensitivity_outcome="$(terminal_field "$sensitivity" outcome)"
  fi
  assert_link "$sensitivity" "$child/effective-input.json" "$kind sensitivity"
  if [[ "$kind" == checksum ]]; then
    [[ $sensitivity_rc -ne 0 ]] || fail "checksum sensitivity unexpectedly accepted wrong effective distribution checksum"
    [[ "$sensitivity_phase" == gradle-bootstrap && "$sensitivity_outcome" == FAIL ]] || fail "checksum sensitivity did not reach Gradle's effective checksum rejection; exit=$sensitivity_rc phase=$sensitivity_phase outcome=$sensitivity_outcome"
    grep -Eq 'checksum|SHA-256|verification failed|does not match' "$sensitivity/gradle-bootstrap.log" || fail "checksum sensitivity lacks Gradle checksum-rejection evidence"
  else
    [[ $sensitivity_rc -eq 0 ]] || fail "$kind sensitivity did not complete the post-guard bootstrap; exit=$sensitivity_rc phase=$sensitivity_phase"
    [[ "$sensitivity_phase" == terminal-evidence ]] || fail "$kind sensitivity lacks successful terminal evidence; phase=$sensitivity_phase"
    [[ "$sensitivity_outcome" == PASS ]] || fail "$kind sensitivity lacks PASS terminal outcome; outcome=$sensitivity_outcome"
  fi

  # Reassociation control: mutate both retained bindings as an attacker would, then submit
  # the rebound evidence to the same validator. The validator derives the authoritative
  # digest from the effective-input bytes rather than trusting an attacker-supplied digest.
  local wrong_digest rebound
  wrong_digest="$(printf 'reassociated:%s\n' "$effective_digest" | sha256sum | awk '{print $1}')"
  rebound="$child/reassociated-evidence"
  mkdir -p "$rebound"
  cp "$corrupt/attempt-basis.json" "$rebound/attempt-basis.json"
  cp "$corrupt/terminal-result.txt" "$rebound/terminal-result.txt"
  sed -i "s/$effective_digest/$wrong_digest/g" "$rebound/attempt-basis.json" "$rebound/terminal-result.txt"
  if evidence_link_valid "$rebound" "$child/effective-input.json"; then
    fail "$kind reassociation control accepted rebound retained evidence"
  fi
  # Validator sensitivity: untouched retained evidence must still be accepted by the exact predicate.
  evidence_link_valid "$corrupt" "$child/effective-input.json" || fail "$kind linkage validator sensitivity rejected authentic retained evidence"
  printf 'effective=%s\nreassociated=%s\nrebound_attempt_submitted=yes\nrebound_terminal_submitted=yes\nvalidator_rejected_rebound=yes\nvalidator_accepted_authentic=yes\nresult=PASS\n' \
    "$effective_digest" "$wrong_digest" > "$child/reassociation-control.txt"

  printf 'negative=%s\neffective_input_sha256=%s\nexpected_phase=%s\nrejection_exit=%s\nsensitivity_exit=%s\nsensitivity_phase=%s\nsensitivity_outcome=%s\npost_guard_boundary=gradle-bootstrap\nresult=PASS\n' \
    "$kind" "$effective_digest" "$expected_phase" "$rc" "$sensitivity_rc" "$sensitivity_phase" "$sensitivity_outcome" > "$child/oracle.txt"
}

run_masking_control() {
  local child="$OUT/earlier-failure-masking"
  mkdir -p "$child"
  set +e
  VERIFY_OUT="$child" VERIFY_INJECT_UNRELATED_FAILURE=1 bash "$VERIFY" gradle-bootstrap >/dev/null 2>&1
  local rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail "masking control unexpectedly passed"
  test -s "$child/attempt-basis.sha256" || fail "masking control never entered child proof path"
  test -s "$child/terminal-result.txt" || fail "masking control lacks retained child terminal evidence"
  local phase outcome
  phase="$(terminal_field "$child" phase)"
  outcome="$(terminal_field "$child" outcome)"
  [[ "$phase" == unrelated-injected-failure && "$outcome" == FAIL ]] || fail "masking control did not retain the injected wrong-phase child failure"
  for forbidden in wrapper-jar-attestation distribution-declaration-attestation proof-cache-confinement; do
    [[ "$phase" != "$forbidden" ]] || fail "wrong-phase masking control satisfied integrity oracle $forbidden"
  done
  printf 'result=PASS\nexit=%s\nphase=%s\noutcome=%s\nchild_attempt_evidence=present\n' "$rc" "$phase" "$outcome" > "$child/oracle.txt"
}

run_negative wrapper wrapper-jar-attestation
run_negative checksum distribution-declaration-attestation
run_negative preseed proof-cache-confinement
run_negative escape proof-cache-confinement
run_masking_control
printf 'spec5_gradle_proof=PASS\n' | tee "$OUT/result.txt"

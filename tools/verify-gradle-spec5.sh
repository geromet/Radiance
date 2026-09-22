#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${VERIFY_OUT:-$ROOT/build/verification-spec5}"
VERIFY="$ROOT/tools/verify-baseline.sh"
mkdir -p "$OUT"

sha256_file() { sha256sum "$1" | awk '{print $1}'; }
fail() { echo "spec5 proof error: $*" >&2; exit 1; }

attempt_binding_valid() {
  local attempt_json="$1" digest="$2"
  python3 - "$attempt_json" "$digest" <<'PY'
import json
import sys

class Pairs(list):
    pass

def pairs_hook(items):
    return Pairs(items)

path, expected_digest = sys.argv[1:3]
try:
    with open(path, "r", encoding="utf-8") as handle:
        root = json.load(handle, object_pairs_hook=pairs_hook)
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)

if not isinstance(root, Pairs):
    raise SystemExit(1)

values = [value for key, value in root if key == "effective_input_sha256"]
if len(values) != 1 or not isinstance(values[0], str) or values[0] != expected_digest:
    raise SystemExit(1)
PY
}

terminal_field() {
  local evidence="$1" field="$2"
  python3 - "$evidence/terminal-result.txt" "$field" <<'PY'
import sys

path, wanted = sys.argv[1:3]
values = []
try:
    with open(path, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            key, sep, value = line.partition("=")
            if sep and key == wanted:
                values.append(value)
except (OSError, UnicodeError):
    raise SystemExit(1)

if len(values) != 1:
    raise SystemExit(1)
print(values[0])
PY
}

evidence_link_valid() {
  local evidence="$1" effective_input="$2" digest terminal_value
  digest="$(sha256_file "$effective_input")"

  attempt_binding_valid "$evidence/attempt-basis.json" "$digest" || return 1
  terminal_value="$(terminal_field "$evidence" effective_input_sha256)" || return 1
  [[ "$terminal_value" == "$digest" ]]
}

declared_negative_valid() {
  local evidence="$1" effective_input="$2" expected_mode="$3" expected_phase="$4" weaken_phase="${5:-0}" digest
  digest="$(sha256_file "$effective_input")"

  attempt_binding_valid "$evidence/attempt-basis.json" "$digest" || return 1

  python3 - "$evidence/terminal-result.txt" "$digest" "$expected_mode" "$expected_phase" "$weaken_phase" <<'PY'
import sys

path, expected_digest, expected_mode, expected_phase, weaken_phase = sys.argv[1:6]
required = ("mode", "phase", "outcome", "exit_code", "effective_input_sha256")
values = {key: [] for key in required}

try:
    with open(path, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            key, sep, value = line.partition("=")
            if sep and key in values:
                values[key].append(value)
except (OSError, UnicodeError):
    raise SystemExit(1)

if any(len(values[key]) != 1 for key in required):
    raise SystemExit(1)

mode = values["mode"][0]
phase = values["phase"][0]
outcome = values["outcome"][0]
exit_code = values["exit_code"][0]
effective_digest = values["effective_input_sha256"][0]

try:
    exit_number = int(exit_code, 10)
except ValueError:
    raise SystemExit(1)

if mode != expected_mode:
    raise SystemExit(1)
if weaken_phase != "1" and phase != expected_phase:
    raise SystemExit(1)
if outcome != "FAIL" or exit_number == 0:
    raise SystemExit(1)
if effective_digest != expected_digest:
    raise SystemExit(1)
PY
}

assert_link() {
  local evidence="$1" effective_input="$2" label="$3"
  evidence_link_valid "$evidence" "$effective_input" || fail "$label retained evidence is not uniquely linked to the effective input bytes"
}

duplicate_terminal_control() {
  local source="$1" target="$2" effective_input="$3" expected_phase="$4" field="$5" wrong_value="$6" position="$7" label="$8"
  mkdir -p "$target"
  cp "$source/attempt-basis.json" "$target/attempt-basis.json"
  if [[ "$position" == prepend ]]; then
    {
      printf '%s=%s\n' "$field" "$wrong_value"
      cat "$source/terminal-result.txt"
    } > "$target/terminal-result.txt"
  else
    cp "$source/terminal-result.txt" "$target/terminal-result.txt"
    printf '%s=%s\n' "$field" "$wrong_value" >> "$target/terminal-result.txt"
  fi

  if declared_negative_valid "$target" "$effective_input" gradle-bootstrap "$expected_phase"; then
    fail "$label shared terminal predicate accepted conflicting duplicate $field field ($position)"
  fi
}

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
  declared_negative_valid "$corrupt" "$child/effective-input.json" gradle-bootstrap "$expected_phase" || fail "$kind retained evidence did not satisfy the shared declared-negative predicate"

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
    sensitivity_phase="$(terminal_field "$sensitivity" phase)" || fail "$kind sensitivity terminal phase is missing or non-canonical"
    sensitivity_outcome="$(terminal_field "$sensitivity" outcome)" || fail "$kind sensitivity terminal outcome is missing or non-canonical"
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

  local wrong_digest rebound duplicate_attempt duplicate_attempt_null duplicate_attempt_number duplicate_attempt_escaped
  wrong_digest="$(printf 'reassociated:%s\n' "$effective_digest" | sha256sum | awk '{print $1}')"
  rebound="$child/reassociated-evidence"
  mkdir -p "$rebound"
  cp "$corrupt/attempt-basis.json" "$rebound/attempt-basis.json"
  cp "$corrupt/terminal-result.txt" "$rebound/terminal-result.txt"
  sed -i "s/$effective_digest/$wrong_digest/g" "$rebound/attempt-basis.json" "$rebound/terminal-result.txt"
  if evidence_link_valid "$rebound" "$child/effective-input.json"; then
    fail "$kind reassociation control accepted rebound retained evidence"
  fi
  evidence_link_valid "$corrupt" "$child/effective-input.json" || fail "$kind linkage validator sensitivity rejected authentic retained evidence"

  duplicate_attempt="$child/duplicate-attempt-binding"
  mkdir -p "$duplicate_attempt"
  cp "$corrupt/attempt-basis.json" "$duplicate_attempt/attempt-basis.json"
  cp "$corrupt/terminal-result.txt" "$duplicate_attempt/terminal-result.txt"
  sed -i "s/}$/,\"effective_input_sha256\":\"$wrong_digest\"}/" "$duplicate_attempt/attempt-basis.json"
  if evidence_link_valid "$duplicate_attempt" "$child/effective-input.json"; then
    fail "$kind linkage validator accepted conflicting duplicate attempt-basis binding"
  fi

  duplicate_attempt_null="$child/duplicate-attempt-null-binding"
  mkdir -p "$duplicate_attempt_null"
  cp "$corrupt/attempt-basis.json" "$duplicate_attempt_null/attempt-basis.json"
  cp "$corrupt/terminal-result.txt" "$duplicate_attempt_null/terminal-result.txt"
  sed -i 's/}$/,"effective_input_sha256":null}/' "$duplicate_attempt_null/attempt-basis.json"
  if evidence_link_valid "$duplicate_attempt_null" "$child/effective-input.json"; then
    fail "$kind linkage validator accepted duplicate null attempt-basis binding"
  fi

  duplicate_attempt_number="$child/duplicate-attempt-number-binding"
  mkdir -p "$duplicate_attempt_number"
  cp "$corrupt/attempt-basis.json" "$duplicate_attempt_number/attempt-basis.json"
  cp "$corrupt/terminal-result.txt" "$duplicate_attempt_number/terminal-result.txt"
  sed -i 's/}$/,"effective_input_sha256":0}/' "$duplicate_attempt_number/attempt-basis.json"
  if evidence_link_valid "$duplicate_attempt_number" "$child/effective-input.json"; then
    fail "$kind linkage validator accepted duplicate numeric attempt-basis binding"
  fi

  duplicate_attempt_escaped="$child/duplicate-attempt-escaped-key-binding"
  mkdir -p "$duplicate_attempt_escaped"
  cp "$corrupt/terminal-result.txt" "$duplicate_attempt_escaped/terminal-result.txt"
  python3 - "$corrupt/attempt-basis.json" "$duplicate_attempt_escaped/attempt-basis.json" "$wrong_digest" <<'PY'
import sys

source, target, wrong_digest = sys.argv[1:4]
with open(source, "r", encoding="utf-8") as handle:
    text = handle.read().rstrip("\n")
if not text.endswith("}"):
    raise SystemExit(1)
escaped_key = r"effective_input_sha\u0032\u0035\u0036"
with open(target, "w", encoding="utf-8") as handle:
    handle.write(text[:-1] + ',"' + escaped_key + '":"' + wrong_digest + '"}\n')
PY
  if evidence_link_valid "$duplicate_attempt_escaped" "$child/effective-input.json"; then
    fail "$kind linkage validator accepted escaped semantic duplicate attempt-basis binding"
  fi

  for position in append prepend; do
    duplicate_terminal_control "$corrupt" "$child/duplicate-terminal-phase-$position" "$child/effective-input.json" "$expected_phase" phase unrelated-injected-failure "$position" "$kind"
    duplicate_terminal_control "$corrupt" "$child/duplicate-terminal-outcome-$position" "$child/effective-input.json" "$expected_phase" outcome PASS "$position" "$kind"
    duplicate_terminal_control "$corrupt" "$child/duplicate-terminal-exit-code-$position" "$child/effective-input.json" "$expected_phase" exit_code 0 "$position" "$kind"
  done
  duplicate_terminal_control "$corrupt" "$child/duplicate-terminal-mode-append" "$child/effective-input.json" "$expected_phase" mode boundary append "$kind"
  duplicate_terminal_control "$corrupt" "$child/duplicate-terminal-effective-input-append" "$child/effective-input.json" "$expected_phase" effective_input_sha256 "$wrong_digest" append "$kind"

  printf 'effective=%s\nreassociated=%s\nrebound_attempt_submitted=yes\nrebound_terminal_submitted=yes\nvalidator_rejected_rebound=yes\nvalidator_rejected_duplicate_attempt=yes\nvalidator_rejected_duplicate_attempt_null=yes\nvalidator_rejected_duplicate_attempt_number=yes\nvalidator_rejected_duplicate_attempt_escaped_key=yes\nshared_predicate_rejected_duplicate_phase_both_orders=yes\nshared_predicate_rejected_duplicate_outcome_both_orders=yes\nshared_predicate_rejected_duplicate_exit_code_both_orders=yes\nshared_predicate_rejected_duplicate_mode=yes\nshared_predicate_rejected_duplicate_effective_input=yes\nvalidator_accepted_authentic=yes\nresult=PASS\n' \
    "$effective_digest" "$wrong_digest" > "$child/reassociation-control.txt"

  printf 'negative=%s\neffective_input_sha256=%s\nexpected_phase=%s\nrejection_exit=%s\nsensitivity_exit=%s\nsensitivity_phase=%s\nsensitivity_outcome=%s\npost_guard_boundary=gradle-bootstrap\nresult=PASS\n' \
    "$kind" "$effective_digest" "$expected_phase" "$rc" "$sensitivity_rc" "$sensitivity_phase" "$sensitivity_outcome" > "$child/oracle.txt"
}

run_masking_control() {
  local child="$OUT/earlier-failure-masking"
  local declared_phase=wrapper-jar-attestation
  local wrapper_digest props_digest effective_digest
  mkdir -p "$child"

  wrapper_digest="$(sha256_file "$ROOT/gradle/wrapper/gradle-wrapper.jar")"
  props_digest="$(sha256_file "$ROOT/gradle/wrapper/gradle-wrapper.properties")"
  write_effective_input "$child/effective-input.json" masking "$wrapper_digest" "$props_digest" attempt-owned-auto absent "$declared_phase"
  effective_digest="$(sha256_file "$child/effective-input.json")"
  printf '%s  %s\n' "$effective_digest" "$child/effective-input.json" > "$child/effective-input.sha256"

  set +e
  VERIFY_OUT="$child" VERIFY_EFFECTIVE_INPUT_SHA256="$effective_digest" VERIFY_INJECT_UNRELATED_FAILURE=1 bash "$VERIFY" gradle-bootstrap >/dev/null 2>&1
  local rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail "masking control unexpectedly passed"
  test -s "$child/attempt-basis.sha256" || fail "masking control never entered child proof path"
  test -s "$child/terminal-result.txt" || fail "masking control lacks retained child terminal evidence"
  assert_link "$child" "$child/effective-input.json" "masking control"

  local phase outcome
  phase="$(terminal_field "$child" phase)" || fail "masking control terminal phase is missing or non-canonical"
  outcome="$(terminal_field "$child" outcome)" || fail "masking control terminal outcome is missing or non-canonical"
  [[ "$phase" == unrelated-injected-failure && "$outcome" == FAIL ]] || fail "masking control did not retain the injected wrong-phase child failure"

  if declared_negative_valid "$child" "$child/effective-input.json" gradle-bootstrap "$declared_phase"; then
    fail "shared declared-negative predicate accepted wrong-phase masking evidence"
  fi
  declared_negative_valid "$child" "$child/effective-input.json" gradle-bootstrap "$declared_phase" 1 || fail "predicate-weakening sensitivity did not make the otherwise-valid wrong-phase evidence acceptable"

  printf 'result=PASS\nexit=%s\nphase=%s\noutcome=%s\nchild_attempt_evidence=present\nshared_predicate_rejected_wrong_phase=yes\npredicate_weakening_accepted_wrong_phase=yes\n' "$rc" "$phase" "$outcome" > "$child/oracle.txt"
}

run_negative wrapper wrapper-jar-attestation
run_negative checksum distribution-declaration-attestation
run_negative preseed proof-cache-confinement
run_negative escape proof-cache-confinement
run_masking_control
printf 'spec5_gradle_proof=PASS\n' | tee "$OUT/result.txt"

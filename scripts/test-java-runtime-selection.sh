#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_CASE="${GALAXYBRIDGE_JAVA_SELECTION_CASE:-all}"
GB_TMP="$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-java-selection.XXXXXX")"
trap 'rm -rf "$GB_TMP"' EXIT

fail() {
  printf 'FAIL java runtime selection: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local context="$3"
  [[ "$actual" == "$expected" ]] ||
    fail "$context (expected '$expected', got '$actual')"
}

assert_contains() {
  local file="$1"
  local expected="$2"
  local context="$3"
  grep -Fq -- "$expected" "$file" || fail "$context"
}

make_java() {
  local home="$1"
  local version="$2"
  local status="${3:-0}"
  mkdir -p "$home/bin"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf "printf 'openjdk version \\\"%s\\\" 2026-07-21 LTS\\n' >&2\n" "$version"
    printf 'exit %s\n' "$status"
  } > "$home/bin/java"
  chmod +x "$home/bin/java"
}

resolved_home() {
  (cd "$1" && pwd -P)
}

run_selector() {
  local error_file="$1"
  shift
  if "$@" > "$GB_TMP/selector.out" 2> "$error_file"; then
    GB_SELECTOR_STATUS=0
  else
    GB_SELECTOR_STATUS=$?
  fi
  GB_SELECTOR_OUTPUT="$(cat "$GB_TMP/selector.out")"
}

test_aggregate_rejects_before_work() {
  local root="$GB_TMP/aggregate-root"
  local marker="$GB_TMP/aggregate-work-started"
  mkdir -p "$root/scripts"
  cp "$GB_ROOT/scripts/verify-local.sh" "$root/scripts/verify-local.sh"
  if [[ -f "$GB_ROOT/scripts/select-java-runtime.sh" ]]; then
    cp "$GB_ROOT/scripts/select-java-runtime.sh" "$root/scripts/select-java-runtime.sh"
  fi
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'touch %q\n' "$marker"
    printf '%s\n' 'exit 91'
  } > "$root/scripts/generate-protocol.sh"
  chmod +x "$root/scripts/generate-protocol.sh"

  local status=0
  if GALAXYBRIDGE_JAVA_HOME="$GB_TMP/does-not-exist" \
      JAVA_HOME="$GB_TMP/fallback" \
      bash "$root/scripts/verify-local.sh" > "$GB_TMP/aggregate.out" 2> "$GB_TMP/aggregate.err"; then
    status=0
  else
    status=$?
  fi

  [[ $status -ne 0 ]] || fail 'aggregate accepted a missing explicit Java home'
  [[ ! -e "$marker" ]] ||
    fail 'aggregate began generate-protocol before rejecting the Java selection'
  assert_contains "$GB_TMP/aggregate.err" 'GALAXYBRIDGE_JAVA_HOME' \
    'aggregate error did not identify the invalid explicit override'
  printf 'PASS aggregate rejects Java before expensive work\n'
}

if [[ "$GB_CASE" == aggregate-early ]]; then
  test_aggregate_rejects_before_work
  exit 0
fi

# Every remaining case exercises the real shared selector.
# shellcheck source=select-java-runtime.sh
source "$GB_ROOT/scripts/select-java-runtime.sh"

GB_DISCOVERED_HOME=''
GB_DISCOVERY_STATUS=0
galaxybridge_macos_java_home() {
  if [[ $GB_DISCOVERY_STATUS -ne 0 ]]; then
    return "$GB_DISCOVERY_STATUS"
  fi
  printf '%s\n' "$GB_DISCOVERED_HOME"
}

select_with_environment() {
  galaxybridge_select_java_home
}

test_precedence_and_spaces() {
  local project_home="$GB_TMP/project override/JDK Home"
  local caller_home="$GB_TMP/caller/JDK Home"
  local discovered_home="$GB_TMP/discovered/JDK Home"
  make_java "$project_home" '21.0.12.1'
  make_java "$caller_home" '21.0.8'
  make_java "$discovered_home" '21.0.7'
  GB_DISCOVERED_HOME="$discovered_home"

  local chosen
  chosen="$(GALAXYBRIDGE_JAVA_HOME="$project_home" JAVA_HOME="$caller_home" select_with_environment)"
  assert_equal "$(resolved_home "$project_home")" "$chosen" \
    'GALAXYBRIDGE_JAVA_HOME did not beat JAVA_HOME and discovery, or spaces were split'

  chosen="$(unset GALAXYBRIDGE_JAVA_HOME; JAVA_HOME="$caller_home" select_with_environment)"
  assert_equal "$(resolved_home "$caller_home")" "$chosen" 'JAVA_HOME did not beat discovery'

  chosen="$(unset GALAXYBRIDGE_JAVA_HOME JAVA_HOME; select_with_environment)"
  assert_equal "$(resolved_home "$discovered_home")" "$chosen" 'macOS discovery was not used last'
  printf 'PASS Java selection precedence and paths with spaces\n'
}

test_invalid_explicit_never_falls_back() {
  local fallback_home="$GB_TMP/valid-fallback"
  make_java "$fallback_home" '21.0.12.1'
  GB_DISCOVERED_HOME="$fallback_home"

  run_selector "$GB_TMP/invalid-explicit.err" env \
    GALAXYBRIDGE_JAVA_HOME="$GB_TMP/missing-explicit" \
    JAVA_HOME="$fallback_home" bash -c \
    'source "$1"; galaxybridge_macos_java_home() { printf "%s\n" "$2"; }; galaxybridge_select_java_home' \
    bash "$GB_ROOT/scripts/select-java-runtime.sh" "$fallback_home"
  [[ $GB_SELECTOR_STATUS -ne 0 ]] || fail 'missing explicit override fell back'
  [[ -z "$GB_SELECTOR_OUTPUT" ]] || fail 'failed explicit override emitted a selected home'
  assert_contains "$GB_TMP/invalid-explicit.err" 'GALAXYBRIDGE_JAVA_HOME' \
    'explicit failure did not name GALAXYBRIDGE_JAVA_HOME'

  run_selector "$GB_TMP/empty-project.err" env \
    GALAXYBRIDGE_JAVA_HOME='' JAVA_HOME="$fallback_home" bash -c \
    'source "$1"; galaxybridge_macos_java_home() { printf "%s\n" "$2"; }; galaxybridge_select_java_home' \
    bash "$GB_ROOT/scripts/select-java-runtime.sh" "$fallback_home"
  [[ $GB_SELECTOR_STATUS -ne 0 ]] || fail 'empty project override fell back'
  assert_contains "$GB_TMP/empty-project.err" 'GALAXYBRIDGE_JAVA_HOME is empty' \
    'empty project override was not identified'

  run_selector "$GB_TMP/invalid-java-home.err" env -u GALAXYBRIDGE_JAVA_HOME \
    JAVA_HOME="$GB_TMP/missing-java-home" bash -c \
    'source "$1"; galaxybridge_macos_java_home() { printf "%s\n" "$2"; }; galaxybridge_select_java_home' \
    bash "$GB_ROOT/scripts/select-java-runtime.sh" "$fallback_home"
  [[ $GB_SELECTOR_STATUS -ne 0 ]] || fail 'invalid JAVA_HOME fell back to discovery'
  assert_contains "$GB_TMP/invalid-java-home.err" 'JAVA_HOME' \
    'caller JAVA_HOME failure did not name JAVA_HOME'
  printf 'PASS invalid explicit Java never falls back\n'
}

expect_rejected_home() {
  local name="$1"
  local home="$2"
  local expected="$3"
  run_selector "$GB_TMP/$name.err" env GALAXYBRIDGE_JAVA_HOME="$home" \
    bash -c 'source "$1"; galaxybridge_select_java_home' bash \
    "$GB_ROOT/scripts/select-java-runtime.sh"
  [[ $GB_SELECTOR_STATUS -ne 0 ]] || fail "$name was accepted"
  [[ -z "$GB_SELECTOR_OUTPUT" ]] || fail "$name emitted a selected home"
  assert_contains "$GB_TMP/$name.err" "$expected" "$name did not report an actionable error"
}

test_invalid_probe_inputs() {
  local nonexec="$GB_TMP/non-executable"
  mkdir -p "$nonexec/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$nonexec/bin/java"
  chmod -x "$nonexec/bin/java"
  expect_rejected_home missing "$GB_TMP/missing-home" 'bin/java'
  expect_rejected_home nonexec "$nonexec" 'executable bin/java'

  local malformed="$GB_TMP/malformed"
  mkdir -p "$malformed/bin"
  printf '%s\n' '#!/usr/bin/env bash' "printf 'not a Java version\\n' >&2" > "$malformed/bin/java"
  chmod +x "$malformed/bin/java"
  expect_rejected_home malformed "$malformed" 'malformed'

  local nonzero="$GB_TMP/nonzero"
  make_java "$nonzero" '21.0.12.1' 7
  expect_rejected_home nonzero "$nonzero" 'version probe failed'
  printf 'PASS missing, non-executable, malformed and nonzero Java probes fail closed\n'
}

test_version_policy() {
  local old="$GB_TMP/jdk-21.0.1"
  local minimum="$GB_TMP/jdk-21.0.3"
  local maintenance="$GB_TMP/jdk-21.0.12.1"
  local other_major="$GB_TMP/jdk-22"
  local early_access="$GB_TMP/jdk-21-ea"
  make_java "$old" '21.0.1'
  make_java "$minimum" '21.0.3'
  make_java "$maintenance" '21.0.12.1'
  make_java "$other_major" '22.0.2'
  make_java "$early_access" '21.0.13-ea'

  expect_rejected_home old "$old" '21.0.3 or newer'
  expect_rejected_home other-major "$other_major" 'JDK 21'
  expect_rejected_home early-access "$early_access" 'early-access'

  local chosen
  chosen="$(GALAXYBRIDGE_JAVA_HOME="$minimum" select_with_environment)"
  assert_equal "$(resolved_home "$minimum")" "$chosen" 'minimum supported JDK was rejected'
  chosen="$(GALAXYBRIDGE_JAVA_HOME="$maintenance" select_with_environment)"
  assert_equal "$(resolved_home "$maintenance")" "$chosen" 'newer JDK 21 maintenance release was rejected'
  printf 'PASS stable JDK 21 minimum and maintenance version policy\n'
}

test_probe_is_bounded() {
  local hung="$GB_TMP/hung"
  local fifo="$GB_TMP/hung.fifo"
  local ready="$GB_TMP/hung.ready"
  local term_observed="$GB_TMP/hung.term-observed"
  mkdir -p "$hung/bin"
  mkfifo "$fifo"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "trap ': > \"\$GALAXYBRIDGE_TEST_TERM_OBSERVED\"; exit 0' TERM"
    printf '%s\n' ': > "$GALAXYBRIDGE_TEST_PROBE_READY"'
    printf '%s\n' 'IFS= read -r _ < "$GALAXYBRIDGE_TEST_HANG_FIFO"'
  } > "$hung/bin/java"
  chmod +x "$hung/bin/java"

  local started ended
  started="$(date +%s)"
  GALAXYBRIDGE_TEST_HANG_FIFO="$fifo" \
    GALAXYBRIDGE_TEST_PROBE_READY="$ready" \
    GALAXYBRIDGE_TEST_TERM_OBSERVED="$term_observed" \
    expect_rejected_home hung "$hung" 'timed out'
  ended="$(date +%s)"
  (( ended - started <= 5 )) || fail 'hung Java probe exceeded its short watchdog'
  [[ -e "$ready" ]] || fail 'TERM-control fake did not report trap readiness'
  [[ -e "$term_observed" ]] || fail 'bounded probe did not allow its TERM-control child to exit on SIGTERM'

  local flood="$GB_TMP/flood"
  mkdir -p "$flood/bin"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "while printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n' >&2; do :; done"
  } > "$flood/bin/java"
  chmod +x "$flood/bin/java"
  expect_rejected_home flood "$flood" 'version probe failed'
  [[ $(wc -c < "$GB_TMP/flood.err") -lt 2048 ]] ||
    fail 'probe failure leaked unbounded executable output into diagnostics'
  printf 'PASS Java version probe time and diagnostics are bounded\n'
}

test_sigterm_ignoring_probe_is_killed_and_reaped() {
  local hung="$GB_TMP/ignores-term"
  local fifo="$GB_TMP/ignores-term.fifo"
  local ready="$GB_TMP/ignores-term.ready"
  local pid_file="$GB_TMP/ignores-term.pid"
  local outer_fired="$GB_TMP/ignores-term.outer-watchdog"
  local error_file="$GB_TMP/ignores-term.err"
  mkdir -p "$hung/bin"
  mkfifo "$fifo"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "trap '' TERM"
    printf '%s\n' 'printf "%s\n" "$$" > "$GALAXYBRIDGE_TEST_PROBE_PID"'
    printf '%s\n' ': > "$GALAXYBRIDGE_TEST_PROBE_READY"'
    printf '%s\n' 'IFS= read -r _ < "$GALAXYBRIDGE_TEST_HANG_FIFO"'
  } > "$hung/bin/java"
  chmod +x "$hung/bin/java"

  env GALAXYBRIDGE_JAVA_HOME="$hung" \
    GALAXYBRIDGE_TEST_HANG_FIFO="$fifo" \
    GALAXYBRIDGE_TEST_PROBE_READY="$ready" \
    GALAXYBRIDGE_TEST_PROBE_PID="$pid_file" \
    bash -c 'source "$1"; galaxybridge_select_java_home' bash \
      "$GB_ROOT/scripts/select-java-runtime.sh" \
      > "$GB_TMP/ignores-term.out" 2> "$error_file" &
  local selector_pid=$!

  local ready_ticks=0
  while [[ ! -e "$ready" ]]; do
    if (( ready_ticks >= 30 )); then
      if [[ -s "$pid_file" ]]; then
        kill -KILL "$(cat "$pid_file")" 2>/dev/null || true
      fi
      kill -KILL "$selector_pid" 2>/dev/null || true
      wait "$selector_pid" 2>/dev/null || true
      fail 'fake Java did not report that its SIGTERM-ignore trap was ready'
    fi
    sleep 0.1
    ready_ticks=$((ready_ticks + 1))
  done

  local probe_pid
  probe_pid="$(cat "$pid_file")"
  [[ "$probe_pid" =~ ^[0-9]+$ ]] || fail 'fake Java reported a malformed PID'
  kill -0 "$probe_pid" 2>/dev/null || fail 'trap-ready fake Java was not running'

  (
    local watchdog_ticks=0
    while kill -0 "$selector_pid" 2>/dev/null; do
      if (( watchdog_ticks >= 50 )); then
        : > "$outer_fired"
        kill -KILL "$probe_pid" 2>/dev/null || true
        exit 0
      fi
      sleep 0.1
      watchdog_ticks=$((watchdog_ticks + 1))
    done
  ) &
  local outer_watchdog_pid=$!

  local selector_status=0
  if wait "$selector_pid"; then
    selector_status=0
  else
    selector_status=$?
  fi
  wait "$outer_watchdog_pid"

  [[ $selector_status -ne 0 ]] || fail 'SIGTERM-ignoring Java probe was accepted'
  assert_contains "$error_file" 'timed out' \
    'SIGTERM-ignoring Java probe did not report its bounded timeout'
  if kill -0 "$probe_pid" 2>/dev/null; then
    kill -KILL "$probe_pid" 2>/dev/null || true
    fail 'SIGTERM-ignoring fake Java remained alive after selector completion'
  fi
  [[ ! -e "$outer_fired" ]] ||
    fail 'selector required the test-owned outer watchdog to kill its probe child'
  printf 'PASS SIGTERM-ignoring Java probe is KILLed and reaped without outer intervention\n'
}

test_discovery_failure() {
  GB_DISCOVERY_STATUS=1
  run_selector "$GB_TMP/discovery.err" bash -c \
    'unset GALAXYBRIDGE_JAVA_HOME JAVA_HOME; source "$1"; galaxybridge_macos_java_home() { return 1; }; galaxybridge_select_java_home' \
    bash "$GB_ROOT/scripts/select-java-runtime.sh"
  [[ $GB_SELECTOR_STATUS -ne 0 ]] || fail 'failed discovery was accepted'
  assert_contains "$GB_TMP/discovery.err" 'could not discover' \
    'discovery failure did not explain how to choose Java'
  GB_DISCOVERY_STATUS=0
  printf 'PASS failed macOS JDK discovery fails closed\n'
}

test_golden_and_aggregate_gradle_wiring() {
  local selected="$GB_TMP/wired JDK/Home"
  local caller="$GB_TMP/wrong-caller"
  local gradle="$GB_TMP/fake-gradle"
  local log="$GB_TMP/gradle.log"
  make_java "$selected" '21.0.12.1'
  make_java "$caller" '21.0.8'
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'printf "%%s|" "$JAVA_HOME" >> %q\n' "$log"
    printf 'printf "%%s " "$@" >> %q\n' "$log"
    printf 'printf "\\n" >> %q\n' "$log"
  } > "$gradle"
  chmod +x "$gradle"

  # Sourcing loads the aggregate's real Gradle unit without running the aggregate.
  # shellcheck source=verify-local.sh
  source "$GB_ROOT/scripts/verify-local.sh"
  local chosen
  chosen="$(GALAXYBRIDGE_JAVA_HOME="$selected" JAVA_HOME="$caller" select_with_environment)"
  if GALAXYBRIDGE_JAVA_HOME="$selected" JAVA_HOME="$caller" \
      galaxybridge_verify_local_gradle_checks "$GB_ROOT" "$gradle" "$chosen" \
      > "$GB_TMP/wiring.out" 2> "$GB_TMP/wiring.err"; then
    :
  else
    cat "$GB_TMP/wiring.out" "$GB_TMP/wiring.err" >&2
    fail 'golden or aggregate Gradle wiring command failed'
  fi
  assert_contains "$GB_TMP/wiring.out" 'PASS GalaxyBridge protobuf golden fixture' \
    'golden fixture did not complete before aggregate Gradle wiring'

  [[ $(wc -l < "$log") -eq 2 ]] ||
    fail 'expected one golden and one aggregate Gradle invocation'
  local first second
  first="$(sed -n '1p' "$log")"
  second="$(sed -n '2p' "$log")"
  [[ "$first" == "$chosen|"*':companion-protocol:testDebugUnitTest '* ]] ||
    fail 'standalone golden Gradle did not receive the selected JAVA_HOME'
  [[ "$second" == "$chosen|"*':app:testInternalDebugUnitTest '* ]] ||
    fail 'aggregate Android Gradle did not receive the selected JAVA_HOME'
  printf 'PASS golden and aggregate Gradle use the same selected JAVA_HOME\n'
}

run_all() {
  test_aggregate_rejects_before_work
  test_precedence_and_spaces
  test_invalid_explicit_never_falls_back
  test_invalid_probe_inputs
  test_version_policy
  test_probe_is_bounded
  test_sigterm_ignoring_probe_is_killed_and_reaped
  test_discovery_failure
  test_golden_and_aggregate_gradle_wiring
  printf 'PASS Java runtime selection regression suite\n'
}

case "$GB_CASE" in
  all) run_all ;;
  precedence) test_precedence_and_spaces ;;
  invalid-explicit) test_invalid_explicit_never_falls_back ;;
  invalid-probes) test_invalid_probe_inputs ;;
  versions) test_version_policy ;;
  bounded) test_probe_is_bounded ;;
  kill-escalation) test_sigterm_ignoring_probe_is_killed_and_reaped ;;
  discovery) test_discovery_failure ;;
  wiring) test_golden_and_aggregate_gradle_wiring ;;
  *) fail "unknown GALAXYBRIDGE_JAVA_SELECTION_CASE '$GB_CASE'" ;;
esac

#!/usr/bin/env bash

galaxybridge_java_error() {
  printf 'GalaxyBridge Java selection failed: %s\n' "$*" >&2
  return 1
}

galaxybridge_macos_java_home() {
  /usr/libexec/java_home -v 21 2>/dev/null
}

galaxybridge_select_java_home() {
  local candidate=''
  local source_name='macOS JDK 21 discovery'

  if [[ ${GALAXYBRIDGE_JAVA_HOME+x} ]]; then
    source_name='GALAXYBRIDGE_JAVA_HOME'
    candidate="$GALAXYBRIDGE_JAVA_HOME"
  elif [[ ${JAVA_HOME+x} ]]; then
    source_name='JAVA_HOME'
    candidate="$JAVA_HOME"
  else
    if ! candidate="$(galaxybridge_macos_java_home)" || [[ -z "$candidate" ]]; then
      galaxybridge_java_error \
        'could not discover a JDK 21; set GALAXYBRIDGE_JAVA_HOME or JAVA_HOME'
      return 1
    fi
  fi

  if [[ -z "$candidate" ]]; then
    galaxybridge_java_error "$source_name is empty"
    return 1
  fi
  if [[ ! -d "$candidate" ]]; then
    galaxybridge_java_error \
      "$source_name selected '$candidate', which does not contain executable bin/java"
    return 1
  fi

  local selected_home
  if ! selected_home="$(cd "$candidate" 2>/dev/null && pwd -P)"; then
    galaxybridge_java_error "$source_name selected an inaccessible Java home at '$candidate'"
    return 1
  fi

  local java_executable="$selected_home/bin/java"
  if [[ ! -x "$java_executable" ]]; then
    galaxybridge_java_error \
      "$source_name selected '$selected_home', which does not contain executable bin/java"
    return 1
  fi

  local probe_dir
  if ! probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-java-probe.XXXXXX")"; then
    galaxybridge_java_error "could not create bounded storage for the '$selected_home' version probe"
    return 1
  fi
  local probe_output="$probe_dir/version-output"
  local timeout_marker="$probe_dir/timed-out"

  (
    ulimit -f 16
    exec "$java_executable" -version
  ) > "$probe_output" 2>&1 &
  local probe_pid=$!

  local probe_ticks=0
  while kill -0 "$probe_pid" 2>/dev/null; do
    if (( probe_ticks >= 20 )); then
      : > "$timeout_marker"
      kill -TERM "$probe_pid" 2>/dev/null || true

      local term_grace_ticks=0
      while kill -0 "$probe_pid" 2>/dev/null && (( term_grace_ticks < 5 )); do
        sleep 0.1
        term_grace_ticks=$((term_grace_ticks + 1))
      done
      if kill -0 "$probe_pid" 2>/dev/null; then
        kill -KILL "$probe_pid" 2>/dev/null || true
      fi
      break
    fi
    sleep 0.1
    probe_ticks=$((probe_ticks + 1))
  done

  local probe_status=0
  if wait "$probe_pid"; then
    probe_status=0
  else
    probe_status=$?
  fi
  if [[ -e "$timeout_marker" ]]; then
    /bin/rm -rf "$probe_dir"
    galaxybridge_java_error "version probe timed out for '$selected_home'"
    return 1
  fi
  if [[ $probe_status -ne 0 ]]; then
    /bin/rm -rf "$probe_dir"
    galaxybridge_java_error "version probe failed for '$selected_home'"
    return 1
  fi

  local version
  version="$(/usr/bin/sed -n 's/^[^\"]*version "\([^\"]*\)".*$/\1/p' "$probe_output" | /usr/bin/head -n 1)"
  /bin/rm -rf "$probe_dir"

  if [[ -z "$version" ]]; then
    galaxybridge_java_error "version probe returned malformed output for '$selected_home'"
    return 1
  fi
  if (( ${#version} > 64 )); then
    galaxybridge_java_error "version probe returned malformed output for '$selected_home'"
    return 1
  fi
  case "$version" in
    *[eE][aA]*)
      galaxybridge_java_error \
        "early-access Java is unsupported at '$selected_home'; use stable JDK 21.0.3 or newer"
      return 1
      ;;
  esac

  if [[ ! "$version" =~ ^([0-9]+)(\.[0-9]+)*(\+[0-9]+(-[[:alnum:]._-]+)?)?$ ]]; then
    galaxybridge_java_error "version probe returned malformed output for '$selected_home'"
    return 1
  fi
  if [[ "${BASH_REMATCH[1]}" != 21 ]]; then
    galaxybridge_java_error \
      "the Java major at '$selected_home' is unsupported; use stable JDK 21.0.3 or newer"
    return 1
  fi
  if [[ ! "$version" =~ ^21\.0\.([0-9]+)(\.[0-9]+)*(\+[0-9]+(-[[:alnum:]._-]+)?)?$ ]]; then
    galaxybridge_java_error \
      "the Java release at '$selected_home' is unsupported; use stable JDK 21.0.3 or newer"
    return 1
  fi
  if (( 10#${BASH_REMATCH[1]} < 3 )); then
    galaxybridge_java_error \
      "the Java release at '$selected_home' is too old; use stable JDK 21.0.3 or newer"
    return 1
  fi

  printf '%s\n' "$selected_home"
}

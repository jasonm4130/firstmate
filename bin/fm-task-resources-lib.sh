#!/usr/bin/env bash
# Task resource helpers for fm-teardown.sh: scans preflight before endpoint
# closure; stops run after closure and the ordinary safety gates. Attribution is current cwd
# under verified task roots; task_process_identity prevents signaling reused PIDs.
# Chrome stop is global, even when invoked from a task directory: authorize it
# only when its PID file, entire process group, and descendants all match the
# cwd scan. Otherwise use the teardown reaper's individual signals.
# Docker has no client-cwd provenance. Only a Compose host working_dir label
# under the verified worktree authorizes stop; unlabelled running containers are
# reported as candidates, never stopped. No container or image is removed.

task_process_is_protected() {  # <pid>
  local command pid=$1 parent depth=0 args
  command=$(ps -p "$1" -o comm= 2>/dev/null) || return 1
  case "$command" in
    *'/Visual Studio Code.app/'*|*'/Code Helper'*|*'/Cursor.app/'*|*'/Zed.app/'*|*'/Sublime Text.app/'*|*'/TextEdit.app/'*|*'/Terminal.app/'*|*'/iTerm.app/'*|code|cursor|zed|nano|vim|nvim|emacs|*/code|*/cursor|*/zed|*/nano|*/vim|*/nvim|*/emacs) return 0 ;;
    *Chrome*|*Chromium*|*chromium*|*/chrome|*Safari*|*WebKit*|*Firefox*|*/firefox)
      # Browser helpers inherit a headless browser's ancestry. A browser with
      # no positively identified headless ancestor is left alone.
      while [ "$depth" -lt 32 ]; do
        args=$(ps -p "$pid" -o command= 2>/dev/null) || return 0
        case " $args " in *' --headless '*|*' --headless='*) return 1 ;; esac
        parent=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]')
        case "$parent" in ''|*[!0-9]*|0|1) return 0 ;; esac
        task_pid_list_contains "$TASK_PIDS" "$parent" || return 0
        pid=$parent
        depth=$((depth + 1))
      done
      return 0 ;;
    *'.app/'*) return 0 ;;
  esac
  return 1
}

task_chrome_member_pids() {  # <process-table> <leader>
  printf '%s\n' "$1" | awk -v leader="$2" '
    NF == 3 { parent[$1] = $2; group[$1] = $3 }
    END {
      member[leader] = 1
      do {
        changed = 0
        for (pid in parent) if (member[parent[pid]] && !member[pid]) {
          member[pid] = 1; changed = 1
        }
      } while (changed)
      for (pid in parent) if (member[pid] || group[pid] == leader) print pid
    }' | sort -n
}

task_signal_pids_under_roots() {  # <dir>...
  local pid
  TASK_PROTECTED_PRESENT=0
  task_pids_under_roots "$@" || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if task_process_is_protected "$pid"; then
      TASK_PROTECTED_PRESENT=1
      case " ${TASK_PROTECTED_REPORTED:-} " in *" $pid "*) ;; *)
        echo "teardown: left process $pid: interactive browser or editor" >&2
        TASK_PROTECTED_REPORTED="${TASK_PROTECTED_REPORTED:-} $pid" ;; esac
    fi
  done <<< "$TASK_PIDS"
  [ "$TASK_PROTECTED_PRESENT" = 0 ]
}

task_resource_scan_refusal() {
  if [ "${TASK_PROTECTED_PRESENT:-0}" = 1 ]; then
    echo "REFUSED: interactive browser or editor remains under task roots for $ID; preserving the worktree and task records" >&2
  else
    echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID (lsof failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
  fi
}

stop_task_chrome_bridges() {  # <dir>...
  local file pid session identity table member parent bridge_group safe command root members current_members
  local state_dir="$HOME/.chrome-devtools-axi"
  if [ "${FM_TEST_SEAM:-0}" = 1 ] && [ -n "${FM_TEST_CHROME_STATE_DIR:-}" ]; then state_dir=$FM_TEST_CHROME_STATE_DIR; fi
  command -v chrome-devtools-axi >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  for file in "$state_dir/bridge.pid" "$state_dir/sessions/"*/bridge.pid; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    pid=$(jq -er '.pid | select(type == "number" and . > 1 and . == floor)' "$file" 2>/dev/null) || continue
    task_pids_under_roots "$@" || return 1
    task_pid_list_contains "$TASK_PIDS" "$pid" || continue
    command=$(ps -p "$pid" -o command= 2>/dev/null) || continue
    case "$command" in *chrome-devtools-axi*bridge*) ;; *) continue ;; esac
    identity=$(task_process_identity "$pid") || continue
    bridge_group=$(ps -p "$pid" -o pgid= 2>/dev/null | tr -d '[:space:]')
    [ "$bridge_group" = "$pid" ] || continue
    table=$(ps -axo pid=,ppid=,pgid= 2>/dev/null) || continue
    # Descendants may create independent groups, so check both ancestry and
    # group membership. Ignore unrelated process churn, including ps itself.
    members=$(task_chrome_member_pids "$table" "$pid")
    task_pid_list_contains "$members" "$pid" || continue
    safe=1
    task_pids_under_roots "$@" || return 1
    while IFS= read -r member; do
      if ! task_pid_list_contains "$TASK_PIDS" "$member" || task_process_is_protected "$member"; then safe=0; break; fi
    done <<< "$members"
    if [ "$safe" != 1 ]; then
      echo "teardown: left chrome stop for bridge $pid: group or descendant is outside task roots or is an editor; using individual cwd signals" >&2
      continue
    fi
    if [ "$file" = "$state_dir/bridge.pid" ]; then session=default
    else session=$(basename "$(dirname "$file")"); fi
    case "$session" in ''|*[!a-zA-Z0-9._-]*|.|..) continue ;; esac
    [ "$(jq -er '.pid' "$file" 2>/dev/null)" = "$pid" ] || continue
    task_process_identity_matches "$pid" "$identity" || continue
    table=$(ps -axo pid=,ppid=,pgid= 2>/dev/null) || continue
    current_members=$(task_chrome_member_pids "$table" "$pid")
    [ "$current_members" = "$members" ] || continue
    [ "$(ps -p "$pid" -o pgid= 2>/dev/null | tr -d '[:space:]')" = "$pid" ] || continue
    root=$1
    for parent in "$@"; do
      [ -n "$parent" ] || continue
      if task_pid_list_contains "$(pids_with_cwd_under "$parent")" "$pid"; then root=$parent; break; fi
    done
    if (cd "$root" && CHROME_DEVTOOLS_AXI_SESSION="$session" fm_run_timed 10 chrome-devtools-axi stop >/dev/null 2>&1) \
       && ! task_process_identity_matches "$pid" "$identity"; then
      echo "teardown: stopped chrome bridge $pid (session $session)" >&2
    else
      echo "teardown: left chrome bridge $pid after stop failed; using individual cwd signals" >&2
    fi
  done
}

stop_task_docker_containers() {  # <canonical-worktree>
  local root=$1 ids id row name working_dir running verified
  [ -n "$root" ] && [ "$root" != / ] || return 0
  command -v docker >/dev/null 2>&1 || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "teardown: left Docker containers: jq unavailable; attribution cannot be read" >&2
    return 0
  fi
  ids=$(fm_run_timed 10 docker ps --no-trunc --quiet 2>/dev/null) || {
    echo "teardown: left Docker containers: running inventory unavailable" >&2
    return 0
  }
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$id" in *[!a-f0-9]*) echo "teardown: left Docker inventory: invalid container identity" >&2; return 0 ;; esac
    row=$(fm_run_timed 10 docker inspect --format '{{json .}}' "$id" 2>/dev/null) || {
      echo "teardown: left container $id: inspection unavailable" >&2; continue
    }
    # Read only the needed values; never print inspect output or environment.
    name=$(printf '%s' "$row" | jq -er '.Name | strings' 2>/dev/null) || name=$id
    running=$(printf '%s' "$row" | jq -r '.State.Running' 2>/dev/null) || running=false
    [ "$running" = true ] || continue
    working_dir=$(printf '%s' "$row" | jq -er '.Config.Labels["com.docker.compose.project.working_dir"] | strings | select(length > 0)' 2>/dev/null) || {
      echo "teardown: left container $id ($name): task attribution unproven (no Compose working_dir label)" >&2; continue
    }
    case "$working_dir" in /*) ;; *) continue ;; esac
    # Resolve a present host path physically, but retain an exact canonical
    # path after Orca has removed the worktree. Dot components never prove it.
    case "$working_dir/" in */../*|*/./*) continue ;; esac
    if [ -d "$working_dir" ]; then working_dir=$(cd "$working_dir" && pwd -P) || continue; fi
    case "$working_dir" in "$root"|"$root"/*) ;; *) continue ;; esac
    verified=$(fm_run_timed 10 docker inspect --format '{{json .}}' "$id" 2>/dev/null) || verified=
    if ! printf '%s' "$verified" | jq -e --arg id "$id" --arg label "$(printf '%s' "$row" | jq -r '.Config.Labels["com.docker.compose.project.working_dir"]')" \
      '.Id == $id and .State.Running == true and .Config.Labels["com.docker.compose.project.working_dir"] == $label' >/dev/null 2>&1; then
      echo "teardown: left container $id ($name): attribution changed before stop" >&2; continue
    fi
    if fm_run_timed 20 docker stop --timeout 10 "$id" >/dev/null 2>&1; then
      echo "teardown: stopped container $id ($name)" >&2
    else
      echo "teardown: left container $id ($name): stop failed" >&2
    fi
  done <<< "$ids"
}

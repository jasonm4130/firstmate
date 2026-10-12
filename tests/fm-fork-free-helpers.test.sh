#!/usr/bin/env bash
# tests/fm-fork-free-helpers.test.sh - the pure-bash stand-ins that the
# watcher, drain, and lock paths use instead of forking small external
# commands every cycle. Each case compares the helper with the command it
# replaces on the same input, under every available Bash (stock macOS
# /bin/bash 3.2 included) and under both the C and a UTF-8 locale, so an edge
# case where the two disagree fails here instead of drifting silently.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-free-helpers)

# Every distinct Bash this host offers: the running one, stock /bin/bash, and
# whatever `bash` resolves to on PATH.
test_interpreters() {
  local seen='' candidate version
  for candidate in "${BASH:-bash}" /bin/bash "$(command -v bash 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    # shellcheck disable=SC2016 # Expanded by the candidate interpreter.
    version=$("$candidate" -c 'printf "%s" "$BASH_VERSION"' 2>/dev/null) || continue
    case " $seen " in *" $version "*) continue ;; esac
    seen="$seen $version"
    printf '%s\n' "$candidate"
  done
}

test_locales() {
  printf '%s\n' C
  if locale -a 2>/dev/null | grep -qx 'C.UTF-8'; then
    printf '%s\n' C.UTF-8
  elif locale -a 2>/dev/null | grep -qx 'en_US.UTF-8'; then
    printf '%s\n' en_US.UTF-8
  fi
}

# Run <script> under every interpreter and locale; any output is a mismatch
# report and fails the case.
run_everywhere() {  # <label> <script> [args...]
  local label=$1 script=$2 interpreter loc out
  shift 2
  while IFS= read -r interpreter; do
    while IFS= read -r loc; do
      out=$(LC_ALL=$loc FM_STATE_OVERRIDE="$TMP_ROOT/state" "$interpreter" "$script" "$ROOT" "$@" 2>&1) \
        || fail "$label failed under $interpreter ($loc): $out"
      [ -z "$out" ] || fail "$label differs under $interpreter ($loc):"$'\n'"$out"
    done < <(test_locales)
  done < <(test_interpreters)
}

test_path_helpers_match_dirname_and_basename() {
  local script="$TMP_ROOT/paths.sh" cases="$TMP_ROOT/path-cases"
  # NUL-separated so paths may carry newlines.
  printf '%s\0' '' / // /// a a/ a// /a /a/ //a a/b a/b/ a//b //a//b/ . .. ./ ../x \
    'a b/c d' 'a/-x' $'a\n/b' $'a/b\n' $'x\n' $'a/b\n\n' $'a\n' $'\n' $'/\n' $'a/\n/' \
    'state/crew.status' '/abs/state/.seen-x' 'x.y.z/.status' '*/?' 'a/[b]' \
    $'caf\xc3\xa9/\xc3\xbc.status' $'\xff\xfe/\xc3.x' $'a/\xff/' > "$cases"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
while IFS= read -r -d '' p; do
  fm_dirname_to got "$p"
  want=$(dirname -- "$p")
  [ "$got" = "$want" ] || printf 'dirname %q: helper %q, command %q\n' "$p" "$got" "$want"
  fm_basename_to got "$p"
  want=$(basename -- "$p")
  [ "$got" = "$want" ] || printf 'basename %q: helper %q, command %q\n' "$p" "$got" "$want"
done < "$2"
SH
  run_everywhere "path helpers" "$script" "$cases"
  pass "fm_dirname_to and fm_basename_to match dirname and basename on every edge case"
}

test_epoch_helper_matches_date_and_never_forks_more() {
  local script="$TMP_ROOT/epoch.sh" shim="$TMP_ROOT/epoch-shim" log="$TMP_ROOT/epoch-date.log"
  mkdir -p "$shim"
  cat > "$shim/date" <<SH
#!/bin/sh
printf 'date\n' >> "$log"
exec $(command -v date) "\$@"
SH
  chmod +x "$shim/date"
  # shellcheck disable=SC2016 # Expanded by the child shell.
  printf '%s\n' '. "$1/bin/fm-wake-lib.sh"' \
    'PATH="$2:$PATH"' \
    ': > "$3"' \
    'before=$(/bin/date +%s)' \
    'fm_epoch_seconds_to now' \
    'after=$(/bin/date +%s)' \
    'case "$now" in ""|*[!0-9]*) printf "not epoch seconds: %q\n" "$now" ;; esac' \
    '[ "$now" -ge "$before" ] && [ "$now" -le "$after" ] || printf "%s outside [%s, %s]\n" "$now" "$before" "$after"' \
    'forks=$(grep -c . "$3" || true)' \
    'if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then' \
    '  [ "$forks" -eq 0 ] || printf "bash %s ran date %s times\n" "$BASH_VERSION" "$forks"' \
    'else' \
    '  [ "$forks" -eq 1 ] || printf "bash %s ran date %s times, not exactly once\n" "$BASH_VERSION" "$forks"' \
    'fi' > "$script"
  run_everywhere "epoch helper" "$script" "$shim" "$log"
  pass "fm_epoch_seconds_to reads the clock like date +%s and forks date at most as often"
}

test_signal_seen_path_and_lock_abs_path_are_unchanged() {
  local script="$TMP_ROOT/seen.sh" dir="$TMP_ROOT/lockdir"
  mkdir -p "$dir/sub" "$TMP_ROOT/state"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
state=$2
for f in "$state/crew.status" "$state/a.b.c.status" "state/x.status" ".status" \
  "$state/crew.turn-ended" "$state/dir/" "x" "a.b/" "/" "$state/q.status.bak"; do
  got=$(fm_wake_signal_seen_path "$state" "$f")
  case "$f" in
    *.status)
      task=$(basename "$f"); task=${task%.status}
      want=$(printf '%s/.seen-%s' "$state" "$(printf '%s.status' "$task" | tr '.' '_')")
      ;;
    *) want=$(printf '%s/.seen-%s' "$state" "$(basename "$f" | tr '.' '_')") ;;
  esac
  [ "$got" = "$want" ] || printf 'seen path %q: helper %q, commands %q\n' "$f" "$got" "$want"
done
cd "$3" || exit 1
for p in "$3/x.lock" "$3/sub/x.lock" "$3//sub//x.lock" "sub/x.lock" "x.lock" "sub/x.lock/" "./sub/../x.lock"; do
  got=$(fm_lock_abs_path "$p")
  want="$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
  [ "$got" = "$want" ] || printf 'lock path %q: helper %q, commands %q\n' "$p" "$got" "$want"
done
SH
  run_everywhere "seen and lock paths" "$script" "$TMP_ROOT/state" "$dir"
  pass "signal seen paths and absolute lock paths are byte-identical to the dirname/basename/tr forms"
}

test_recovery_marker_read_accepts_exactly_one_newline() {
  local script="$TMP_ROOT/marker.sh" cases="$TMP_ROOT/marker-cases"
  mkdir -p "$cases"
  printf 'pending:handling:g1\n' > "$cases/one"
  printf 'pending:handling:g1' > "$cases/unterminated"
  printf 'pending:handling:g1\npending:handling:g2\n' > "$cases/two"
  printf 'pending:handling:g1\ntrailing-partial' > "$cases/partial-second"
  : > "$cases/empty"
  printf '\n' > "$cases/blank"
  printf 'announced:downtime:g\0x\n' > "$cases/nul"
  printf 'acked:handling:g1\r\n' > "$cases/crlf"
  printf 'pending:handling:g1\n\n' > "$cases/blank-second"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
for marker in "$2"/*; do
  # The replaced reference: one newline byte by wc -l, then the same token read.
  want=reject
  if [ "$(wc -l < "$marker" | tr -d '[:space:]')" = 1 ] && IFS= read -r line < "$marker"; then
    case "$line" in
      pending:handling:*|pending:downtime:*|announced:handling:*|announced:downtime:*|acked:handling:*|acked:downtime:*)
        case "${line##*:}" in ''|*[!A-Za-z0-9._-]*) ;; *) want="accept:$line" ;; esac ;;
    esac
  fi
  if fm_recovery_marker_read "$marker"; then got="accept:$FM_RECOVERY_MARKER_TOKEN"; else got=reject; fi
  [ "$got" = "$want" ] || printf 'marker %s: helper %q, reference %q\n' "${marker##*/}" "$got" "$want"
done
SH
  run_everywhere "recovery marker read" "$script" "$cases"
  pass "recovery marker reads accept exactly the one-line records wc -l accepted"
}

test_window_to_task_matches_the_meta_pipeline() {
  local script="$TMP_ROOT/window.sh" state="$TMP_ROOT/window-state"
  mkdir -p "$state"
  printf 'window=sess:w1\nbackend=tmux\n' > "$state/alpha.meta"
  printf 'window=old\nwindow=sess:w2\n' > "$state/beta.meta"
  printf 'terminal=term-3\nwindow=\n' > "$state/gamma.meta"
  printf 'window=a=b=c' > "$state/delta.meta"
  printf 'window=sess:w5\r\n' > "$state/eps.meta"
  printf ' window=sess:w6\nwindow= sess:w6 \n' > "$state/zeta.meta"
  printf 'terminal=t7\nterminal=\n' > "$state/eta.meta"
  mkdir -p "$state/dir.meta"
  printf 'window=sess:w9\n' > "$state/theta.meta"
  chmod 000 "$state/theta.meta"
  cat > "$script" <<'SH'
. "$1/bin/fm-classify-lib.sh"
state=$2
reference() {  # the replaced grep | tail -1 | cut -d= -f2- lookup
  local w=$1 meta mw mt t
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
    t=$(basename "$meta"); printf '%s' "${t%.meta}"; return 0
  done
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}
for w in sess:w1 old sess:w2 term-3 '' a=b=c a sess:w5 $'sess:w5\r' ' sess:w6 ' sess:w6 t7 sess:w9 sess:fm-fallback-x unknown; do
  got=$(window_to_task "$w" "$state")
  want=$(reference "$w")
  [ "$got" = "$want" ] || printf 'window %q: helper %q, pipeline %q\n' "$w" "$got" "$want"
done
SH
  run_everywhere "window_to_task" "$script" "$state"
  chmod 600 "$state/theta.meta"
  pass "window_to_task resolves every recorded window exactly as the grep/tail/cut pipeline did"
}

test_classify_stat_helpers_read_the_kernel_name_once() {
  local script="$TMP_ROOT/uname.sh" shim="$TMP_ROOT/uname-shim" log="$TMP_ROOT/uname.log" file="$TMP_ROOT/sized"
  mkdir -p "$shim"
  cat > "$shim/uname" <<SH
#!/bin/sh
printf 'uname\n' >> "$log"
exec $(command -v uname) "\$@"
SH
  chmod +x "$shim/uname"
  printf 'caf\303\251 bytes\n' > "$file"
  cat > "$script" <<'SH'
PATH="$2:$PATH"
: > "$3"
. "$1/bin/fm-classify-lib.sh"
for _ in 1 2 3 4 5; do
  size=$(_fm_status_file_size "$4")
  [ "$size" = "$(LC_ALL=C wc -c < "$4" | tr -d ' ')" ] || printf 'size %q\n' "$size"
  mtime=$(_fm_status_file_mtime "$4")
  case "$mtime" in ''|*[!0-9]*) printf 'mtime %q\n' "$mtime" ;; esac
  _fm_open_decisions_file_ident "$4" >/dev/null || printf 'identity unreadable\n'
done
calls=$(grep -c . "$3" || true)
[ "$calls" -eq 1 ] || printf 'uname ran %s times for 15 stat reads\n' "$calls"
SH
  run_everywhere "classify stat helpers" "$script" "$shim" "$log" "$file"
  pass "classify stat helpers resolve the kernel name once per process"
}

# A logging stand-in for sleep, so a case can count how often a wait started it.
make_sleep_shim() {  # <shim-dir> <log>
  mkdir -p "$1"
  cat > "$1/sleep" <<SH
#!/bin/sh
printf 'sleep\n' >> "$2"
exec $(command -v sleep) "\$@"
SH
  chmod +x "$1/sleep"
}

# The shared preamble of the fm_sleep cases: a sub-second clock that does not
# go through the sleep shim, an elapsed-time check, and a sleep-start counter.
# shellcheck disable=SC2016 # Expanded by each case's child shell.
SLEEP_CASE_PREAMBLE='. "$1/bin/fm-wake-lib.sh"
PATH="$2:$PATH"
log=$3
: > "$log"
now() { perl -MTime::HiRes=time -e "printf q(%.3f), time"; }
pause() { perl -e "select undef, undef, undef, \$ARGV[0]" "$1"; }
within() {  # <start> <min> <max> <label>
  local took
  took=$(perl -e "printf q(%.3f), \$ARGV[1] - \$ARGV[0]" "$1" "$(now)")
  perl -e "exit !(\$ARGV[0] >= \$ARGV[1] && \$ARGV[0] < \$ARGV[2])" "$took" "$2" "$3" \
    || printf "bash %s: %s took %ss, outside [%s, %s)\n" "$BASH_VERSION" "$4" "$took" "$2" "$3"
}
sleeps() {  # <expected> <label>: compare and reset the sleep-start count
  local n
  n=$(grep -c . "$log" 2>/dev/null) || n=0
  : > "$log"
  [ "$n" -eq "$1" ] || printf "bash %s: %s started sleep %s times, not %s\n" "$BASH_VERSION" "$2" "$n" "$1"
}
modern=0
[ "${BASH_VERSINFO[0]}" -lt 4 ] || modern=1
'

test_sleep_helper_waits_without_starting_sleep() {
  local script="$TMP_ROOT/sleep.sh" shim="$TMP_ROOT/sleep-shim" log="$TMP_ROOT/sleep.log"
  make_sleep_shim "$shim" "$log"
  # shellcheck disable=SC2016 # Expanded by the child shell.
  printf '%s\n' "$SLEEP_CASE_PREAMBLE" \
    't=$(now); fm_sleep 1; within "$t" 1 2.5 "an unopened whole-second wait"' \
    'sleeps 1 "an unopened whole-second wait"' \
    'fm_sleep_open' \
    't=$(now); fm_sleep 1; within "$t" 1 2.5 "a whole-second wait"' \
    'sleeps 0 "a whole-second wait"' \
    't=$(now); fm_sleep 0.3; within "$t" 0.3 1.5 "a fractional wait"' \
    'sleeps $((1 - modern)) "a fractional wait"' \
    't=$(now); fm_sleep 0; within "$t" 0 0.5 "a zero wait"' \
    'sleeps 0 "a zero wait"' \
    'exec 19<&-' \
    't=$(now); fm_sleep 1; within "$t" 1 2.5 "a wait whose descriptor was closed"' \
    'sleeps 1 "a wait whose descriptor was closed"' \
    't=$(now); fm_sleep 1; within "$t" 1 2.5 "the wait after a closed descriptor"' \
    'sleeps 1 "the wait after a closed descriptor"' > "$script"
  run_everywhere "fm_sleep timing" "$script" "$shim" "$log"
  pass "fm_sleep waits its full time inside bash, and falls back to sleep without a usable FIFO"
}

test_sleep_helper_survives_a_trap_that_exits_mid_wait() {
  local script="$TMP_ROOT/sleep-exit.sh" child="$TMP_ROOT/sleep-exit-child.sh"
  local shim="$TMP_ROOT/sleep-exit-shim" log="$TMP_ROOT/sleep-exit.log"
  make_sleep_shim "$shim" "$log"
  # A TERM trap that exits while the wait is pending, then an EXIT trap whose
  # work outlasts the wait's timeout: a read -t timer left armed in this shell
  # would fire inside that work and hang or abort Bash.
  cat > "$child" <<'SH'
. "$1/bin/fm-wake-lib.sh"
done_file=$2
trap 'perl -e "select undef, undef, undef, 1.5"; x=$(printf ok); printf "%s" "$x" > "$done_file"' EXIT
trap 'exit 143' TERM
fm_sleep_open
: > "$done_file.ready"
while :; do fm_sleep 1; done
SH
  # shellcheck disable=SC2016 # Expanded by the child shell.
  printf '%s\n' "$SLEEP_CASE_PREAMBLE" \
    'done_file="$log.cleanup"' \
    'rm -f "$done_file" "$done_file.ready"' \
    '"$BASH" "$4" "$1" "$done_file" &' \
    'child=$!' \
    'for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -e "$done_file.ready" ] && break; pause 0.5; done' \
    'pause 0.2' \
    't=$(now)' \
    'kill -TERM "$child"' \
    'for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do kill -0 "$child" 2>/dev/null || break; pause 0.5; done' \
    'if kill -0 "$child" 2>/dev/null; then kill -KILL "$child"; printf "bash %s: a shell TERMed mid-wait hung in its EXIT trap\n" "$BASH_VERSION"; fi' \
    'wait "$child"; rc=$?' \
    '[ "$rc" -eq 143 ] || printf "bash %s: a shell TERMed mid-wait exited %s, not 143\n" "$BASH_VERSION" "$rc"' \
    '[ "$(cat "$done_file" 2>/dev/null)" = ok ] || printf "bash %s: the EXIT trap did not finish its work\n" "$BASH_VERSION"' \
    'within "$t" 1.5 6 "a TERMed wait plus its EXIT trap"' \
    'sleeps 0 "a TERMed whole-second wait"' > "$script"
  run_everywhere "fm_sleep exit trap" "$script" "$shim" "$log" "$child"
  pass "a trap that exits during fm_sleep leaves its EXIT trap free to finish"
}

test_identity_helpers_match_the_pipelines_they_replace() {
  local script="$TMP_ROOT/identity.sh" pids='' pid
  perl -e 'sleep 60' -- 'two  spaces' "$(printf 'tab\there')" 'trailing   ' >/dev/null 2>&1 &
  pids="$pids $!"
  perl -e 'sleep 60' -- "$(printf 'caf\303\251')" "$(printf 'bad\377byte')" >/dev/null 2>&1 &
  pids="$pids $!"
  sleep 60 &
  pids="$pids $!"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
. "$1/bin/fm-supervision-engine-lib.sh"
shift
for pid in "$@"; do
  got=$(FM_PROC_ROOT_OVERRIDE=/nonexistent fm_pid_identity "$pid")
  want=$(COLUMNS=10000 LC_ALL=C ps -p "$pid" -o lstart= -o command= | sed 's/^[[:space:]]*//')
  [ -n "$got" ] && [ "$got" = "$want" ] || printf 'fm_pid_identity %s: helper %q, pipeline %q\n' "$pid" "$got" "$want"
  got=$(_fm_engine_identity "$pid")
  want=$(printf '%s\n' "$(fm_pid_identity "$pid")" | tr '\t\n' '  ' | sed 's/ *$//')
  [ -n "$got" ] && [ "$got" = "$want" ] || printf '_fm_engine_identity %s: helper %q, pipeline %q\n' "$pid" "$got" "$want"
done
SH
  # shellcheck disable=SC2086 # One argument per recorded pid.
  run_everywhere "identity helpers" "$script" $pids
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done
  pass "fm_pid_identity and _fm_engine_identity match the sed and tr pipelines they replace"
}

test_pr_file_helpers_read_the_kernel_name_once() {
  local script="$TMP_ROOT/pr-uname.sh" shim="$TMP_ROOT/pr-uname-shim" log="$TMP_ROOT/pr-uname.log" file="$TMP_ROOT/pr-file"
  mkdir -p "$shim"
  cat > "$shim/uname" <<SH
#!/bin/sh
printf 'uname\n' >> "$log"
exec $(command -v uname) "\$@"
SH
  chmod +x "$shim/uname"
  : > "$file"
  cat > "$script" <<'SH'
PATH="$2:$PATH"
: > "$3"
. "$1/bin/fm-wake-lib.sh"
. "$1/bin/fm-pr-lib.sh"
for _ in 1 2 3; do
  for read_one in fm_pr_file_mode fm_pr_file_device fm_pr_file_inode fm_pr_file_link_count; do
    value=$("$read_one" "$4")
    case "$value" in ''|*[!0-9]*) printf '%s %q\n' "$read_one" "$value" ;; esac
  done
done
calls=$(grep -c . "$3" || true)
[ "$calls" -eq 1 ] || printf 'uname ran %s times for 12 stat reads\n' "$calls"
SH
  run_everywhere "pr file helpers" "$script" "$shim" "$log" "$file"
  pass "fm_pr_file helpers resolve the kernel name once per process beside the wake library"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
else
  test_path_helpers_match_dirname_and_basename
  test_epoch_helper_matches_date_and_never_forks_more
  test_signal_seen_path_and_lock_abs_path_are_unchanged
  test_recovery_marker_read_accepts_exactly_one_newline
  test_window_to_task_matches_the_meta_pipeline
  test_classify_stat_helpers_read_the_kernel_name_once
  test_sleep_helper_waits_without_starting_sleep
  test_sleep_helper_survives_a_trap_that_exits_mid_wait
  test_identity_helpers_match_the_pipelines_they_replace
  test_pr_file_helpers_read_the_kernel_name_once
fi

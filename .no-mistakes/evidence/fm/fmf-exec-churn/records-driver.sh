#!/usr/bin/env bash
set -eu
lab=$(mktemp -d "$PWD/.test-disposable/records.XXXXXX")
trap 'rm -rf "$lab"' EXIT
export FM_HOME="$lab"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
mkdir "$lab/state"
. bin/fm-backend.sh
. bin/fm-wake-lib.sh
printf 'harness=claude\nharness=\nharness=a=b\nharness=unterminated' > "$lab/state/worker.meta"
values=$(fm_meta_values "$lab/state/worker.meta" harness)
printf 'recorded harness values: %q\n' "$values"
[ "$values" = $'claude\n\na=b\nunterminated' ]
printf ' spaces\tand\\slashes\nlast unterminated' > "$lab/state/value"
value=$(fm_read_file "$lab/state/value")
printf 'read value: %q\n' "$value"
[ "$value" = $' spaces\tand\\slashes\nlast unterminated' ]
fm_current_pid parent
fm_lock_acquire_wait "$lab/state/parent.lock"
result=$(cat < <(
 fm_current_pid child
 [ "$child" != "$parent" ] || exit 1
 fm_lock_acquire_wait "$lab/state/child.lock"
 [ "$(fm_read_file "$lab/state/child.lock/pid")" = "$child" ] || exit 1
 fm_lock_release "$lab/state/child.lock"
 if fm_lock_try_acquire "$lab/state/parent.lock"; then echo FAIL; exit 1; fi
 printf 'child=%s parent=%s parent lock retained\n' "$child" "$parent"
))
printf '%s\n' "$result"
case "$result" in child=*) ;; *) exit 1 ;; esac
[ "$(fm_read_file "$lab/state/parent.lock/pid")" = "$parent" ]
fm_lock_release "$lab/state/parent.lock"
echo 'PASS: recorded values retained and child cannot take the parent lock'

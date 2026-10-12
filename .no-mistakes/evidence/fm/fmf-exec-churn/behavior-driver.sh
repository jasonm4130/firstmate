#!/usr/bin/env bash
set -eu
root=$PWD
lab=$(mktemp -d "$PWD/.test-disposable/scenario.XXXXXX")
trap 'rm -rf "$lab"' EXIT
bash bin/fm-lab-home.sh create "$lab" >/dev/null
export FM_HOME="$lab" TMPDIR="$root/.test-disposable" FM_PROCEVENT_CLAIM_ROOT="$lab/claims"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_TEST_SEAM FM_TEST_EPOCH_SECONDS_FILE
printf '=== registered custom check delivered by real monitor ===\n'
printf '#!/usr/bin/env bash\nprintf "live check delivered\\n"\n' > "$lab/state/live.check.sh"
chmod 700 "$lab/state/live.check.sh"
bash bin/fm-check-register.sh live
FM_CHECK_INTERVAL=1 bash bin/fm-watch-checkpoint.sh --seconds 10
bash bin/fm-wake-drain.sh
printf '=== status notification at production poll and grace ===\n'
rm -f "$lab/state/live.check.sh"
printf 'done: disposable end-to-end notification\n' > "$lab/state/demo.status"
bash bin/fm-watch-checkpoint.sh --seconds 50
bash bin/fm-wake-drain.sh
printf '=== quiet reconciliation then reject unsafe outcome-directory replacement ===\n'
bash bin/fm-inactive-reconcile.sh scan --startup
bash bin/fm-inactive-reconcile.sh scan
rm -rf "$lab/state/terminal-outcomes"
mkdir "$lab/foreign-outcomes"
ln -s "$lab/foreign-outcomes" "$lab/state/terminal-outcomes"
if bash bin/fm-inactive-reconcile.sh scan; then echo 'FAIL: symlinked outcome directory accepted'; exit 1; else echo 'PASS: unsafe outcome-directory replacement rejected'; fi
printf '=== fresh private identities and monotonic leases ===\n'
. bin/fm-wake-lib.sh
. bin/fm-pr-lib.sh
. bin/fm-procevent-lib.sh
mkdir -m 700 "$lab/state/procevent" "$lab/private"
before=$(fm_procevent_private_directory_identity "$lab/private" 1)
mv "$lab/private" "$lab/private-old"
mkdir -m 700 "$lab/private"
after=$(fm_procevent_private_directory_identity "$lab/private" 1)
printf 'before=%s\nafter=%s\n' "$before" "$after"
[ "$before" != "$after" ]
chmod 777 "$lab/private"
if fm_procevent_private_directory_identity "$lab/private" 1; then exit 1; else echo 'PASS: writable private directory rejected'; fi
fm_procevent_owner_lease_touch "$lab/state"
before=$(fm_read_file "$lab/state/procevent/.owner-lease")
fm_procevent_owner_lease_touch "$lab/state"
after=$(fm_read_file "$lab/state/procevent/.owner-lease")
printf 'lease-before=%s lease-after=%s mode=%s age=%s\n' "$before" "$after" "$(fm_pr_file_mode "$lab/state/procevent/.owner-lease")" "$(fm_procevent_owner_lease_age "$lab/state")"
[ "$before" != "$after" ]
[ "$(fm_pr_file_mode "$lab/state/procevent/.owner-lease")" = 600 ]
echo 'PASS: real monitoring, notifications, reconciliation, identities and lease publication'

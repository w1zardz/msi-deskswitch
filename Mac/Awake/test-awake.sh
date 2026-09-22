#!/bin/bash
# Exercises the daemon state machine without root, I/O Registry, or power changes.
set -euo pipefail
task_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$task_dir/deskswitch-awake.sh"

on_ac() { [[ "$mock_ac" == 1 ]]; }
monitor_attached() { [[ "$mock_monitor" == 1 ]]; }
kvm_on_mac() { [[ "$mock_kvm" == 1 ]]; }
lid_closed() { [[ "$mock_lid" == 1 ]]; }
sleep_disabled() { [[ "$mock_disabled" == 1 ]]; }
set_disabled() { actions="${actions}disable:$1 "; mock_disabled="$1"; }
wake_display() { actions="${actions}wake "; }
request_sleep() { actions="${actions}sleep "; }
log() { messages="${messages}$*"$'\n'; }

checks=0
expect() {
    checks=$((checks + 1))
    if [[ "$1" != "$2" ]]; then
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$3" "$2" "$1" >&2
        exit 1
    fi
}
fixture() {
    reset_state
    mock_ac=1 mock_monitor=0 mock_kvm=0 mock_lid=1 mock_disabled=0
    actions="" messages=""
    grace=90
}

fixture
mock_kvm=1
update_state 100
expect "$actions" "disable:1 wake " "First authorized MSI USB appearance protects and wakes before framebuffer"
expect "$last_seen" 100 "USB bootstraps the confirmed dock timestamp"
expect "$last_state" "ac=1 monitor=0 kvm=1 protection=1 reason=msi-usb" "Logs the USB-only reason"
actions=""; messages=""
update_state 101
expect "$actions" "" "Steady dock does not repeatedly wake or modify sleep"
expect "$messages" "" "Steady state does not flood the log"
mock_monitor=1
update_state 102
expect "$actions" "" "Framebuffer discovery after USB does not wake again"

fixture
mock_monitor=1 mock_kvm=1 mock_disabled=1
update_state 100
expect "$actions" "wake " "Daemon startup wakes even when KVM and sleep protection already exist"

fixture
mock_monitor=1
update_state 100
expect "$actions" "disable:1 wake " "First framebuffer activation wakes with KVM still on Windows"
actions=""
mock_kvm=1
update_state 101
expect "$actions" "wake " "Normal Windows-to-Mac USB return wakes"
actions=""
update_state 102
expect "$actions" "" "The same USB attachment only wakes once"
mock_kvm=0
update_state 103
mock_kvm=1
update_state 104
expect "$actions" "wake " "A later KVM return still wakes"

fixture
mock_monitor=1
update_state 100
actions=""
mock_monitor=0
update_state 101
update_state 189
expect "$actions" "" "Temporary dock loss preserves the full 90-second grace"
expect "$mock_disabled" 1 "Protection remains during detach grace"
update_state 190
expect "$actions" "disable:0 sleep " "Grace expiry restores sleep and sleeps a closed lid"
actions=""; messages=""
update_state 191
expect "$actions" "" "Expired state does not repeatedly request sleep"
expect "$messages" "" "Expired steady state does not repeatedly log"

fixture
mock_monitor=1
update_state 100
mock_monitor=0
update_state 101
actions=""
mock_kvm=1
update_state 190
expect "$actions" "wake " "USB return at the deadline is processed before any sleep decision"
expect "$mock_disabled" 1 "USB return before framebuffer preserves protection"
expect "$last_seen" 190 "USB return renews the dock timestamp"

fixture
mock_monitor=1
update_state 100
actions=""
mock_ac=0
update_state 101
expect "$actions" "disable:0 sleep " "Battery immediately restores sleep despite cached monitor or grace"
expect "$last_seen" -1 "Battery discards stale dock grace"
actions=""
mock_monitor=0 mock_ac=1
update_state 102
expect "$actions" "" "Unrelated AC cannot revive the old dock protection"

fixture
mock_ac=0 mock_kvm=1
update_state 100
expect "$actions" "" "MSI USB on battery neither protects nor wakes"
mock_ac=1
update_state 101
expect "$actions" "disable:1 wake " "Power return with a confirmed dock activates and wakes"

fixture
mock_monitor=1 mock_lid=0
update_state 100
actions=""
mock_monitor=0
update_state 190
expect "$actions" "disable:0 " "Open lid restores normal sleep without forcing immediate sleep"

fixture
mock_disabled=1
update_state 100
expect "$actions" "disable:0 sleep " "Startup without a confirmed dock does not grant unconditional AC grace"

printf 'PASS: %s Awake state checks (mocked power and hardware; no system changes)\n' "$checks"

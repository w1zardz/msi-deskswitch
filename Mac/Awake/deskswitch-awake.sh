#!/bin/bash
# Keeps a closed MacBook awake while it is powered and the MSI monitor is attached.
# Runs as root from launchd: toggles `pmset disablesleep`, restores sleep on exit.
set -u

monitor="${DESKSWITCH_MONITOR:-MAG322UPF}"
kvm_device="${DESKSWITCH_KVM_DEVICE:-MSI Gaming Controller}"
interval="${DESKSWITCH_INTERVAL:-1}"
grace="${DESKSWITCH_GRACE:-90}"
display_hold_timeout=30
display_hold_renew=15

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

on_ac() { /usr/bin/pmset -g ps | /usr/bin/head -1 | /usr/bin/grep -q "AC Power"; }
monitor_attached() {
    /usr/sbin/ioreg -lw0 -r -c IOMobileFramebufferShim | /usr/bin/grep -q "\"ProductName\"=\"[^\"]*${monitor}"
}
kvm_on_mac() { /usr/sbin/ioreg -p IOUSB -w0 | /usr/bin/grep -qF -- "-o ${kvm_device}@"; }
lid_closed() { /usr/sbin/ioreg -r -k AppleClamshellState -d 1 | /usr/bin/grep -q '"AppleClamshellState" = Yes'; }
sleep_disabled() { /usr/bin/pmset -g | /usr/bin/grep -qE '^ *SleepDisabled[[:space:]]+1'; }

set_disabled() {
    /usr/bin/pmset -a disablesleep "$1" && log "disablesleep $1"
}

wake_display() { /usr/bin/caffeinate -u -t 5 & }
request_sleep() { /usr/bin/pmset sleepnow >/dev/null; }

display_hold_alive() { [[ -n "$display_hold_pid" ]] && kill -0 "$display_hold_pid" 2>/dev/null; }
start_display_hold() {
    # -d keeps USB-C video available even while the KVM is on Windows. A short
    # lease and parent tracking bound protection if this loop stalls or dies.
    /usr/bin/caffeinate -d -t "$display_hold_timeout" -w "$$" &
    display_hold_pid=$!
}
retire_display_hold() {
    kill "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}
ensure_display_hold() {
    local now="$1" old_pid="$display_hold_pid" alive=0
    display_hold_alive && alive=1
    if (( alive == 1 && now >= display_hold_started && now - display_hold_started < display_hold_renew )); then
        return
    fi
    # A forked child may not have acquired its assertion yet. Keep the current
    # lease through the next renewal; only retire the lease from two renewals
    # ago, while the middle lease still protects the display.
    start_display_hold
    display_hold_started=$now
    if (( alive == 1 )); then
        [[ -z "$display_hold_previous_pid" ]] || retire_display_hold "$display_hold_previous_pid"
        display_hold_previous_pid="$old_pid"
    else
        # Keep any earlier overlap while replacing a child that died early.
        [[ -z "$old_pid" ]] || retire_display_hold "$old_pid"
    fi
    if (( alive == 0 )); then
        log "display idle protection enabled: pid=${display_hold_pid} lease=${display_hold_timeout}s renew=${display_hold_renew}s"
    fi
}
stop_display_hold() {
    if [[ -n "$display_hold_pid" ]]; then
        retire_display_hold "$display_hold_pid"
        [[ -z "$display_hold_previous_pid" ]] || retire_display_hold "$display_hold_previous_pid"
        display_hold_pid=""
        display_hold_previous_pid=""
        log "display idle protection released"
    fi
}

restore() {
    trap - TERM INT HUP EXIT
    stop_display_hold
    set_disabled 0
    exit 0
}

reset_state() {
    last_seen=-1
    kvm_was_on_mac=0
    dock_was_present=0
    protection_was_wanted=0
    last_state=""
    display_hold_pid=""
    display_hold_previous_pid=""
    display_hold_started=0
}

# Take one snapshot before deciding whether to sleep or wake. MSI USB can be
# authorized before its framebuffer appears, particularly on the first docking.
update_state() {
    local now="$1" ac=0 display=0 kvm=0 dock=0 want=0 disabled=0 reason state
    on_ac && ac=1
    monitor_attached && display=1
    kvm_on_mac && kvm=1
    (( display == 1 || kvm == 1 )) && dock=1

    if (( ac == 0 )); then
        # A later connection to an unrelated charger must not revive dock grace.
        last_seen=-1
        reason="battery"
    elif (( dock == 1 )); then
        last_seen=$now
        want=1
        if (( display == 1 )); then reason="monitor"; else reason="msi-usb"; fi
    elif (( last_seen >= 0 && now - last_seen < grace )); then
        want=1
        reason="detach-grace"
    else
        reason="dock-absent"
    fi

    state="ac=${ac} monitor=${display} kvm=${kvm} protection=${want} reason=${reason}"
    if [[ "$state" != "$last_state" ]]; then log "state: $state"; last_state="$state"; fi
    sleep_disabled && disabled=1

    if (( want == 1 )); then
        ensure_display_hold "$now"
        (( disabled == 1 )) || set_disabled 1
        if (( dock == 1 && (protection_was_wanted == 0 || dock_was_present == 0 || disabled == 0) )); then
            log "dock activated: waking display (${reason})"
            wake_display
        elif (( kvm == 1 && kvm_was_on_mac == 0 )); then
            log "kvm returned to mac: waking display"
            wake_display
        fi
    else
        # Drop the display assertion before allowing a closed Mac to sleep.
        stop_display_hold
        if (( disabled == 1 )); then
            # powerd does not re-check the lid after disablesleep is cleared.
            if set_disabled 0 && lid_closed; then
                log "lid closed without dock protection: sleeping (${reason})"
                request_sleep
            fi
        fi
    fi

    kvm_was_on_mac=$kvm
    dock_was_present=$dock
    protection_was_wanted=$want
}

main() {
    if ! [[ "$interval" =~ ^[1-9][0-9]*$ && "$grace" =~ ^[1-9][0-9]*$ ]]; then
        log "interval and grace must be positive integer seconds"
        return 1
    fi
    if (( interval >= display_hold_timeout - display_hold_renew )); then
        log "interval must be less than $((display_hold_timeout - display_hold_renew)) seconds to renew display protection"
        return 1
    fi
    trap restore TERM INT HUP EXIT
    reset_state
    log "start: monitor=${monitor} kvm=${kvm_device} interval=${interval}s grace=${grace}s display-lease=${display_hold_timeout}s"
    while true; do
        update_state "$(date +%s)"
        sleep "$interval"
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main; fi

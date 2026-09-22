#!/bin/bash
# Keeps a closed MacBook awake while it is powered and the MSI monitor is attached.
# Runs as root from launchd: toggles `pmset disablesleep`, restores sleep on exit.
set -u

monitor="${DESKSWITCH_MONITOR:-MAG322UPF}"
kvm_device="${DESKSWITCH_KVM_DEVICE:-MSI Gaming Controller}"
interval="${DESKSWITCH_INTERVAL:-1}"
grace="${DESKSWITCH_GRACE:-90}"

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

restore() {
    trap - TERM INT HUP EXIT
    set_disabled 0
    exit 0
}

reset_state() {
    last_seen=-1
    kvm_was_on_mac=0
    dock_was_present=0
    protection_was_wanted=0
    last_state=""
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
        (( disabled == 1 )) || set_disabled 1
        if (( dock == 1 && (protection_was_wanted == 0 || dock_was_present == 0 || disabled == 0) )); then
            log "dock activated: waking display (${reason})"
            wake_display
        elif (( kvm == 1 && kvm_was_on_mac == 0 )); then
            log "kvm returned to mac: waking display"
            wake_display
        fi
    elif (( disabled == 1 )); then
        # powerd does not re-check the lid after disablesleep is cleared.
        if set_disabled 0 && lid_closed; then
            log "lid closed without dock protection: sleeping (${reason})"
            request_sleep
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
    trap restore TERM INT HUP EXIT
    reset_state
    log "start: monitor=${monitor} kvm=${kvm_device} interval=${interval}s grace=${grace}s"
    while true; do
        update_state "$(date +%s)"
        sleep "$interval"
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main; fi

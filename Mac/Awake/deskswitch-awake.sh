#!/bin/bash
# Keeps a closed MacBook awake while it is powered and the MSI monitor is attached.
# Runs as root from launchd: toggles `pmset disablesleep`, restores sleep on exit.
set -u

monitor="${DESKSWITCH_MONITOR:-MAG322UPF}"
kvm_device="${DESKSWITCH_KVM_DEVICE:-MSI Gaming Controller}"
interval="${DESKSWITCH_INTERVAL:-5}"
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

restore() {
    set_disabled 0
    exit 0
}
trap restore TERM INT HUP EXIT

last_seen=0
kvm_was_on_mac=0
kvm_on_mac && kvm_was_on_mac=1
log "start: monitor=${monitor} kvm=${kvm_device}"

while true; do
    now=$(date +%s)
    want=0
    if on_ac; then
        if monitor_attached; then
            last_seen=$now
            want=1
        elif (( now - last_seen < grace )); then
            want=1
        fi
    fi

    if (( want == 1 )); then
        sleep_disabled || set_disabled 1
    elif sleep_disabled; then
        set_disabled 0
        # powerd does not re-check the lid after disablesleep is cleared.
        if lid_closed; then
            log "lid closed without monitor or power: sleeping"
            /usr/bin/pmset sleepnow >/dev/null
        fi
    fi

    # KVM handed USB back to the Mac: wake the display so the monitor sees USB-C signal.
    if kvm_on_mac; then
        if (( kvm_was_on_mac == 0 )); then
            log "kvm returned to mac: waking display"
            /usr/bin/caffeinate -u -t 5 &
        fi
        kvm_was_on_mac=1
    else
        kvm_was_on_mac=0
    fi

    sleep "$interval"
done

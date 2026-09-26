#!/bin/bash
# Installs the closed-lid awake daemon. Asks for the administrator password once.
set -euo pipefail
dir="$(cd -- "$(dirname -- "$0")" && pwd)"
label="ru.w1zardz.msi-deskswitch.awake"
script="/Library/PrivilegedHelperTools/deskswitch-awake.sh"
plist="/Library/LaunchDaemons/${label}.plist"

sudo /bin/mkdir -p /Library/PrivilegedHelperTools
sudo /bin/launchctl bootout "system/${label}" 2>/dev/null || true
sudo /usr/bin/install -o root -g wheel -m 755 "$dir/deskswitch-awake.sh" "$script"
sudo /usr/bin/install -o root -g wheel -m 644 "$dir/${label}.plist" "$plist"
# bootout returns before the old shell has necessarily finished its TERM trap.
# Wait out that shutdown instead of failing with bootstrap error 5 during updates.
loaded=0
for attempt in {1..15}; do
    if sudo /bin/launchctl bootstrap system "$plist"; then
        loaded=1
        break
    fi
    sleep 1
done
[[ "$loaded" == 1 ]] || { printf '%s\n' 'Не удалось запустить Awake.' >&2; exit 1; }
sleep 2
state="$(sudo /bin/launchctl print "system/${label}")"
printf '%s\n' "$state" | /usr/bin/grep -q 'state = running'
printf '%s\n' "$state" | /usr/bin/grep -qE 'pid = [1-9][0-9]*'
printf '%s\n' 'Установлено. Лог: /var/log/deskswitch-awake.log' ''
sudo /usr/bin/tail -5 /var/log/deskswitch-awake.log || true
/usr/bin/pmset -g | /usr/bin/grep -E 'SleepDisabled' || true
if [[ -t 0 ]]; then printf '\n%s' 'Нажми Enter для выхода… '; read -r _ || true; fi

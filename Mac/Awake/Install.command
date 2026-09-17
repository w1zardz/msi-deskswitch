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
sudo /bin/launchctl bootstrap system "$plist"
sleep 2
printf '%s\n' 'Установлено. Лог: /var/log/deskswitch-awake.log' ''
sudo /usr/bin/tail -5 /var/log/deskswitch-awake.log || true
/usr/bin/pmset -g | /usr/bin/grep -E 'SleepDisabled' || true
if [[ -t 0 ]]; then printf '\n%s' 'Нажми Enter для выхода… '; read -r _ || true; fi

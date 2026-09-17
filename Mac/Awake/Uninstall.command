#!/bin/bash
# Removes the awake daemon and turns normal sleep back on.
set -euo pipefail
label="ru.w1zardz.msi-deskswitch.awake"
sudo /bin/launchctl bootout "system/${label}" 2>/dev/null || true
sudo /bin/rm -f "/Library/LaunchDaemons/${label}.plist" /Library/PrivilegedHelperTools/deskswitch-awake.sh
sudo /usr/bin/pmset -a disablesleep 0
printf '%s\n' 'Удалено, обычный сон включён.'
if [[ -t 0 ]]; then printf '\n%s' 'Нажми Enter для выхода… '; read -r _ || true; fi

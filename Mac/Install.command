#!/bin/bash
set -euo pipefail
task_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    printf '%s\n' 'Этот пакет предназначен для Mac на Apple Silicon.'
    exit 1
fi
task_brew=''
for task_candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$task_candidate" ]]; then task_brew="$task_candidate"; break; fi
done
if [[ -z "$task_brew" ]]; then
    printf '%s\n' 'Homebrew не найден. В README описана установка без Homebrew.'
    printf '%s\n' 'Ничего не изменено. Нажми Enter для выхода.'
    read -r task_reply
    exit 1
fi
"$task_brew" install m1ddc
if [[ ! -d /Applications/Hammerspoon.app && ! -d "$HOME/Applications/Hammerspoon.app" ]]; then
    "$task_brew" install --cask hammerspoon
fi
task_config="$HOME/.hammerspoon"
mkdir -p "$task_config"
task_stamp="$(date +%Y%m%d-%H%M%S)"
if [[ -f "$task_config/desk-switch.lua" ]]; then
    cp -p "$task_config/desk-switch.lua" "$task_config/desk-switch.lua.backup-$task_stamp"
fi
cp "$task_dir/desk-switch.lua" "$task_config/desk-switch.lua"
task_init="$task_config/init.lua"
task_line='deskSwitchMSI = require("desk-switch")'
if [[ ! -f "$task_init" ]] || ! grep -Fq "$task_line" "$task_init"; then
    if [[ -f "$task_init" ]]; then cp -p "$task_init" "$task_init.backup-$task_stamp"; fi
    printf '\n%s\n' "$task_line" >> "$task_init"
fi
open -a Hammerspoon
printf '%s\n' 'Разреши Hammerspoon управление в Универсальном доступе, затем Reload Config в его меню.'
printf '%s\n' 'PageDown — возврат в Windows. Mac ↔ PC — меню сверху.'
printf '%s\n' 'В настройках Hammerspoon включи Launch Hammerspoon at login.'
printf '%s\n' 'Нажми Enter для выхода.'
read -r task_reply

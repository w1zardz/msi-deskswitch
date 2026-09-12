#!/bin/bash
set -euo pipefail
task_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
task_source="$task_dir/MSI DeskSwitch.app"
task_apps="$HOME/Applications"
task_destination="$task_apps/MSI DeskSwitch.app"

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    printf '%s\n' 'Этот пакет предназначен для Mac на Apple Silicon.' >&2
    exit 1
fi
task_major="$(sw_vers -productVersion | cut -d . -f 1)"
[[ "$task_major" -ge 13 ]] || { printf '%s\n' 'Нужна macOS 13 Ventura или новее.' >&2; exit 1; }
[[ -d "$task_source" ]] || { printf '%s\n' 'Рядом с Install.command должен лежать MSI DeskSwitch.app. Сначала распакуй весь ZIP.' >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$task_source"
mkdir -p "$task_apps"
task_stage="$(mktemp -d "$task_apps/.deskswitch-install.XXXXXX")"
task_backup=''
trap 'rm -rf -- "$task_stage"' EXIT
/usr/bin/ditto "$task_source" "$task_stage/MSI DeskSwitch.app"
/usr/bin/codesign --verify --deep --strict "$task_stage/MSI DeskSwitch.app"

# NSRunningApplication sends a normal termination request without System Events
# or Apple Events permissions and never launches an absent instance.
/usr/bin/osascript -l JavaScript <<'JXA'
ObjC.import('AppKit');
const appID = 'ru.w1zardz.msi-deskswitch';
const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(appID);
for (let i = 0; i < apps.count; i++) apps.objectAtIndex(i).terminate;
let remaining = 0;
for (let attempt = 0; attempt < 50; attempt++) {
    remaining = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(appID).count;
    if (remaining === 0) break;
    delay(0.1);
}
if (remaining > 0) throw new Error('Закрой MSI DeskSwitch через его меню и запусти установку ещё раз.');
JXA

if [[ -e "$task_destination" || -L "$task_destination" ]]; then
    task_backup="$task_apps/MSI DeskSwitch.backup-$(date +%Y%m%d-%H%M%S)-$$.app"
    mv "$task_destination" "$task_backup"
fi
if ! mv "$task_stage/MSI DeskSwitch.app" "$task_destination"; then
    if [[ -n "$task_backup" ]]; then mv "$task_backup" "$task_destination"; fi
    printf '%s\n' 'Не удалось установить приложение. Предыдущая версия восстановлена.' >&2
    exit 1
fi
printf 'Установлено: %s\n' "$task_destination"
if [[ -n "$task_backup" ]]; then printf 'Предыдущая версия: %s\n' "$task_backup"; fi
if [[ -f "$HOME/.hammerspoon/desk-switch.lua" ]] || \
   { [[ -f "$HOME/.hammerspoon/init.lua" ]] && /usr/bin/grep -Eq 'desk-switch|deskSwitchMSI' "$HOME/.hammerspoon/init.lua"; }; then
    printf '\n%s\n' 'Найден старый модуль DeskSwitch в Hammerspoon.' \
        'Удали или закомментируй только строку подключения desk-switch в ~/.hammerspoon/init.lua и нажми Reload Config в Hammerspoon.' \
        'Иначе оба приложения могут перехватывать PageDown. Установщик конфиг не меняет.'
fi
/usr/bin/open "$task_destination"
printf '\n%s\n' 'DeskSwitch появился в строке меню. Настройки и разрешения доступны в его окне.' \
    'Для удаления: выйди из приложения, выключи запуск при входе и перенеси приложение в Корзину.'
if [[ -t 0 ]]; then
    printf '\n%s' 'Нажми Enter для выхода… '
    read -r task_reply || true
fi

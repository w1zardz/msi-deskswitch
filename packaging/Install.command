#!/bin/bash
set -euo pipefail
task_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
task_log="$task_dir/Install.log"
exec > >(tee -a "$task_log") 2>&1
task_fail() {
    printf '\n%s\n' "$1"
    printf '%s\n' 'Нажми Enter, чтобы закрыть окно.'
    read -r task_reply || true
    exit 1
}
trap 'task_fail "Установка остановлена. Подробности находятся в Install.log рядом с установщиком."' ERR
[[ "$(uname -s)" == Darwin ]] || task_fail 'Запусти этот файл на Mac.'
task_arm="$(sysctl -n hw.optional.arm64 2>/dev/null || true)"
[[ "$task_arm" == 1 ]] || task_fail 'Этот пакет предназначен для Mac с чипом Apple M-серии.'
task_os="$(sw_vers -productVersion)"
task_major="${task_os%%.*}"
[[ "$task_major" -ge 13 ]] || task_fail 'Для этого пакета требуется macOS 13 или новее.'
printf '%s\n' 'Настройка MSI: PageDown → Windows'
cd "$task_dir"
printf '%s\n' '11bb1c90faf5427f37c7bd4fe7eab9774ae43e1d5cb020c5b3088dac32849efa  Hammerspoon-1.1.1.zip' \
    'fd4b3c88cd24a1992cb6eb8fa0c82edc301ef5831de19416cc5691c758b4b03d  m1ddc-1.2.0-arm64-ventura.tar.gz' | /usr/bin/shasum -a 256 -c -
task_tmp="$(mktemp -d "${TMPDIR:-/tmp}/msi-deskswitch.XXXXXX")"
task_cleanup() {
    case "$task_tmp" in
        "${TMPDIR:-/tmp}"/msi-deskswitch.*) /bin/rm -rf -- "$task_tmp" ;;
    esac
}
trap task_cleanup EXIT
task_config="$HOME/.hammerspoon"
mkdir -p "$task_config/desk-switch-bin"
tar -xzf "$task_dir/m1ddc-1.2.0-arm64-ventura.tar.gz" -C "$task_tmp"
/usr/bin/install -m 755 "$task_tmp/m1ddc/1.2.0/bin/m1ddc" "$task_config/desk-switch-bin/m1ddc"
cp "$task_tmp/m1ddc/1.2.0/LICENSE" "$task_config/desk-switch-bin/m1ddc-LICENSE"
if [[ -d /Applications/Hammerspoon.app ]]; then
    task_app=/Applications/Hammerspoon.app
elif [[ -d "$HOME/Applications/Hammerspoon.app" ]]; then
    task_app="$HOME/Applications/Hammerspoon.app"
else
    /usr/bin/ditto -x -k "$task_dir/Hammerspoon-1.1.1.zip" "$task_tmp/hammerspoon"
    /usr/bin/codesign --verify --deep --strict "$task_tmp/hammerspoon/Hammerspoon.app"
    mkdir -p "$HOME/Applications"
    task_app="$HOME/Applications/Hammerspoon.app"
    /usr/bin/ditto "$task_tmp/hammerspoon/Hammerspoon.app" "$task_app"
fi
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
printf '\n%s\n' 'Проверка подключённых дисплеев:'
"$task_config/desk-switch-bin/m1ddc" display list || printf '%s\n' 'MSI пока не обнаружен: подключи USB-C и разбуди Mac.'
open "$task_app"
printf '\n%s\n' 'Файлы установлены.'
printf '%s\n' '1. Разреши Hammerspoon управление в разделе «Универсальный доступ» настроек Mac.'
printf '%s\n' '2. В меню Hammerspoon сверху выбери Reload Config.'
printf '%s\n' '3. Должно появиться меню «Mac ↔ PC».'
printf '%s\n' 'PageDown возвращает монитор, клавиатуру и мышь в Windows.'
printf '%s\n' 'Автозапуск включится при загрузке модуля. Проверку горячей клавиши делай после выдачи разрешения.'
printf '\n%s\n' 'Нажми Enter, чтобы закрыть окно.'
read -r task_reply || true

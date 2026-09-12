#!/bin/bash
set -euo pipefail

task_native="$(cd -- "$(dirname -- "$0")" && pwd)"
task_root="$(cd -- "$task_native/../.." && pwd)"
task_output=''
task_cache="$task_root/.cache"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output|--cache)
            [[ $# -ge 2 ]] || { printf 'Missing value for %s\n' "$1" >&2; exit 2; }
            if [[ "$1" == --output ]]; then task_output="$2"; else task_cache="$2"; fi
            shift 2 ;;
        -h|--help)
            printf '%s\n' 'Usage: Mac/Native/build.sh [--output /path/DeskSwitch-Mac-Native.zip] [--cache /path/cache]'
            exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[[ "$(uname -s)" == Darwin ]] || { printf '%s\n' 'Build requires macOS and Xcode command-line tools.' >&2; exit 1; }
command -v python3 >/dev/null || { printf '%s\n' 'Build requires Python 3.' >&2; exit 1; }
xcrun --find swiftc >/dev/null
# Python.org installations may have no default certificate bundle on macOS.
# Use the system CA file while preserving explicitly configured certificate paths.
if [[ -z "${SSL_CERT_FILE:-}" && -z "${SSL_CERT_DIR:-}" && -r /etc/ssl/cert.pem ]]; then
    export SSL_CERT_FILE=/etc/ssl/cert.pem
fi
mkdir -p "$task_root/dist" "$task_cache"
task_stage="$(mktemp -d "$task_root/dist/.native-build.XXXXXX")"
trap 'rm -rf -- "$task_stage"' EXIT
task_release="$task_stage/native"
task_app="$task_release/MSI DeskSwitch.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources/Licenses"

python3 - "$task_root" "$task_cache" "$task_app/Contents/Resources" <<'PY'
import importlib.util
import json
from pathlib import Path
import struct
import sys
import tarfile

root, cache, resources = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location('legacy_packaging', root / 'packaging/build_mac.py')
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)
digest = 'fd4b3c88cd24a1992cb6eb8fa0c82edc301ef5831de19416cc5691c758b4b03d'
name = 'm1ddc-1.2.0-arm64-ventura.tar.gz'
headers = None
if not (cache / name).is_file():
    token = json.loads(packaging.fetch('https://ghcr.io/token?service=ghcr.io&scope=repository:homebrew/core/m1ddc:pull'))['token']
    headers = {'Authorization': 'Bearer ' + token, 'User-Agent': 'MSI-DeskSwitch-build'}
archive_path = packaging.cached(cache, name, digest, 'https://ghcr.io/v2/homebrew/core/m1ddc/blobs/sha256:' + digest, headers)
with tarfile.open(archive_path, 'r:gz') as archive:
    binary = archive.extractfile('m1ddc/1.2.0/bin/m1ddc').read()
    header = struct.unpack_from('<IiiIIIII', binary)
    if header[0] != 0xFEEDFACF or header[1] != 0x100000C:
        raise RuntimeError('Expected arm64 Mach-O m1ddc')
    offset = 32
    for _ in range(header[4]):
        command, size = struct.unpack_from('<II', binary, offset)
        if size < 8 or offset + size > len(binary):
            raise RuntimeError('Invalid Mach-O load command')
        if command in (0xC, 0x80000018, 0x8000001F, 0x20, 0x80000023):
            start = offset + struct.unpack_from('<I', binary, offset + 8)[0]
            dependency = binary[start:offset + size].split(b'\0', 1)[0].decode()
            if not dependency.startswith(('/usr/lib/', '/System/Library/')):
                raise RuntimeError('Non-system m1ddc dependency: ' + dependency)
        offset += size
    (resources / 'm1ddc').write_bytes(binary)
    (resources / 'm1ddc').chmod(0o755)
    (resources / 'Licenses/m1ddc-LICENSE').write_bytes(archive.extractfile('m1ddc/1.2.0/LICENSE').read())
print('Verified pinned m1ddc archive, architecture and system dependencies.')
PY

cp "$task_native/Info.plist" "$task_app/Contents/Info.plist"
cp "$task_root/LICENSE" "$task_app/Contents/Resources/Licenses/DeskSwitch-LICENSE"
cp "$task_root/THIRD_PARTY.md" "$task_app/Contents/Resources/Licenses/THIRD_PARTY.md"
printf '%s\n' 'Building MSI DeskSwitch for Apple Silicon / macOS 13+…'
xcrun swiftc -O -whole-module-optimization -parse-as-library \
    -target arm64-apple-macos13.0 \
    -framework AppKit -framework SwiftUI -framework Carbon -framework CoreAudio \
    "$task_native/Core.swift" "$task_native/Controller.swift" \
    "$task_native/HotKeys.swift" "$task_native/Keyboard.swift" \
    "$task_native/DeskSwitchApp.swift" "$task_native/GoXLR.swift" "$task_native/AudioOutput.swift" \
    "$task_native/HeadphonesOverlay.swift" \
    -o "$task_app/Contents/MacOS/MSI DeskSwitch"
xcrun swift "$task_native/make-icon.swift" "$task_stage/AppIcon.iconset"
/usr/bin/iconutil -c icns "$task_stage/AppIcon.iconset" -o "$task_app/Contents/Resources/AppIcon.icns"
/usr/bin/plutil -lint "$task_app/Contents/Info.plist"

# Keep the default ad-hoc designated requirement, bound to this build's code hash.
# Stable identity across updates requires Developer ID signing, not an identifier-only rule.
/usr/bin/codesign --force --sign - --identifier ru.w1zardz.msi-deskswitch.m1ddc \
    "$task_app/Contents/Resources/m1ddc"
/usr/bin/codesign --force --sign - --identifier ru.w1zardz.msi-deskswitch \
    "$task_app"
/usr/bin/codesign --verify --deep --strict "$task_app"
cp "$task_native/Install.command" "$task_release/Install.command"
cp "$task_native/README.md" "$task_release/README.md"
cp "$task_root/LICENSE" "$task_root/THIRD_PARTY.md" "$task_release/"
chmod 755 "$task_release/Install.command"

rm -rf -- "$task_root/dist/native"
mv "$task_release" "$task_root/dist/native"
if [[ -n "$task_output" ]]; then
    mkdir -p "$(dirname -- "$task_output")"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$task_root/dist/native" "$task_stage/DeskSwitch-Mac-Native.zip"
    mv -f "$task_stage/DeskSwitch-Mac-Native.zip" "$task_output"
    /usr/bin/shasum -a 256 "$task_output"
fi
printf 'Ready: %s\n' "$task_root/dist/native/MSI DeskSwitch.app"

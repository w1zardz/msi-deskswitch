#!/usr/bin/env python3
"""Build the pinned offline Mac bundle using Python's standard library."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
HAMMER_HASH = '11bb1c90faf5427f37c7bd4fe7eab9774ae43e1d5cb020c5b3088dac32849efa'
M1_HASH = 'fd4b3c88cd24a1992cb6eb8fa0c82edc301ef5831de19416cc5691c758b4b03d'

def fetch(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {'User-Agent': 'MSI-DeskSwitch-build'})
    with urllib.request.urlopen(req, timeout=120) as response:
        return response.read()

def cached(cache, name, digest, url, headers=None):
    path = cache / name
    data = path.read_bytes() if path.exists() else fetch(url, headers)
    if hashlib.sha256(data).hexdigest() != digest:
        raise RuntimeError('SHA-256 mismatch: ' + name)
    if not path.exists(): path.write_bytes(data)
    return path

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cache', type=Path, default=ROOT / '.cache')
    parser.add_argument('--output', type=Path, default=ROOT / 'dist' / 'DeskSwitch-Mac.zip')
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    hammer = cached(args.cache, 'Hammerspoon-1.1.1.zip', HAMMER_HASH,
                    'https://github.com/Hammerspoon/hammerspoon/releases/download/1.1.1/Hammerspoon-1.1.1.zip')
    m1name = 'm1ddc-1.2.0-arm64-ventura.tar.gz'
    headers = None
    if not (args.cache / m1name).exists():
        token = json.loads(fetch('https://ghcr.io/token?service=ghcr.io&scope=repository:homebrew/core/m1ddc:pull'))['token']
        headers = {'Authorization': 'Bearer ' + token, 'User-Agent': 'MSI-DeskSwitch-build'}
    m1 = cached(args.cache, m1name, M1_HASH,
                'https://ghcr.io/v2/homebrew/core/m1ddc/blobs/sha256:' + M1_HASH, headers)
    with tarfile.open(m1, 'r:gz') as archive:
        binary = archive.extractfile('m1ddc/1.2.0/bin/m1ddc').read()
        header = struct.unpack_from('<IiiIIIII', binary)
        if header[0] != 0xFEEDFACF or header[1] != 0x100000C:
            raise RuntimeError('Expected an arm64 Mach-O executable')
        offset = 32
        for _ in range(header[4]):
            command, size = struct.unpack_from('<II', binary, offset)
            if command in (0xC, 0x80000018, 0x8000001F):
                start = offset + struct.unpack_from('<I', binary, offset + 8)[0]
                name = binary[start:offset + size].split(b'\0', 1)[0].decode()
                if not name.startswith(('/usr/lib/', '/System/Library/')):
                    raise RuntimeError('Non-system dependency: ' + name)
            offset += size
    with zipfile.ZipFile(hammer) as archive:
        if archive.testzip() is not None: raise RuntimeError('Invalid Hammerspoon archive')
    files = [ROOT / 'packaging' / 'Install.command', ROOT / 'packaging' / 'START.txt',
             ROOT / 'Mac' / 'desk-switch.lua', ROOT / 'LICENSE', ROOT / 'THIRD_PARTY.md', hammer, m1]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, 'w') as archive:
        for path in files:
            item = zipfile.ZipInfo('DeskSwitch-Mac/' + path.name)
            item.create_system = 3
            item.external_attr = (0o100755 if path.suffix == '.command' else 0o100644) << 16
            binary = path.suffix in ('.zip', '.gz')
            data = path.read_bytes()
            if not binary: data = data.replace(b'\r\n', b'\n')
            item.compress_type = zipfile.ZIP_STORED if binary else zipfile.ZIP_DEFLATED
            archive.writestr(item, data)
    with zipfile.ZipFile(args.output) as archive:
        if archive.testzip() is not None: raise RuntimeError('Bundle integrity failed')
        if archive.getinfo('DeskSwitch-Mac/Install.command').external_attr >> 16 != 0o100755:
            raise RuntimeError('Executable permission missing')
    print('Created', args.output.name, 'SHA256', hashlib.sha256(args.output.read_bytes()).hexdigest())

if __name__ == '__main__': main()

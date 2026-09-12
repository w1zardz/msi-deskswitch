#!/usr/bin/env python3
"""Exercise the real URLSession client and production ATS plist against loopback only."""
import http.server
import json
import pathlib
import plistlib
import subprocess
import tempfile
import threading
import time

native = pathlib.Path(__file__).resolve().parent
volume = 128
requests = []


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        requests.append(('GET', self.path))
        self.send_error(500)

    def do_POST(self):
        global volume
        assert self.path == '/api/command'
        assert self.headers.get('Content-Type') == 'application/json'
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(('POST', body))
        status, result = 200, 'Ok'
        if body == 'GetStatus':
            result = {'Status': {'mixers': {'TEST': {'levels': {'volumes': {'Headphones': volume}}}}}}
        else:
            serial, command = body['Command']
            channel, value = command['SetVolume']
            assert channel == 'Headphones' and type(value) is int and 0 <= value <= 255
            if serial == 'TEST':
                volume = value
            elif serial == 'ERROR':
                result = {'Error': 'Device disconnected'}
            elif serial == 'HTTP500':
                status = 500
            elif serial == 'MALFORMED':
                result = {'unexpected': True}
            elif serial == 'REDIRECT':
                self.send_response(302)
                self.send_header('Location', f'http://127.0.0.1:{self.server.server_port}/forbidden')
                self.end_headers()
                return
            elif serial == 'TIMEOUT':
                time.sleep(2.5)
            else:
                raise AssertionError('Unexpected target device')
        encoded = json.dumps(result).encode()
        try:
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
        except (BrokenPipeError, ConnectionResetError):
            pass  # The timeout test deliberately closes its socket.


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='deskswitch-http-') as tmp:
        app = pathlib.Path(tmp) / 'Probe.app' / 'Contents'
        binary = app / 'MacOS' / 'Probe'
        binary.parent.mkdir(parents=True)
        info = plistlib.loads((native / 'Info.plist').read_bytes())
        info['CFBundleIdentifier'] = 'ru.w1zardz.msi-deskswitch.http-tests'
        info['CFBundleExecutable'] = 'Probe'
        (app / 'Info.plist').write_bytes(plistlib.dumps(info))
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-target', 'arm64-apple-macos13.0',
                        str(native / 'GoXLR.swift'), str(native / 'GoXLRHTTPTests.swift'), '-o', str(binary)], check=True)
        subprocess.run([str(binary), str(server.server_port)], check=True, timeout=25)
        assert not any(method == 'GET' for method, _ in requests), 'A redirect was followed'
        assert volume == 133, 'Unexpected volume mutation'
finally:
    server.shutdown()
    server.server_close()

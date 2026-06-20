#!/usr/bin/env bash
set -euo pipefail

host="${MIRADOR_VERIFY_HOST:-127.0.0.1}"
port="${MIRADOR_VERIFY_PORT:-8787}"
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //' || true)"
if [[ -z "$account_home" ]]; then
  account_home="$HOME"
fi
token_file="${MIRADOR_TOKEN_FILE:-$account_home/.mirador-token}"
if [[ ! -s "$token_file" ]]; then
  echo "ERROR: token file not found: $token_file" >&2
  exit 2
fi

MIRADOR_VERIFY_HOST="$host" \
MIRADOR_VERIFY_PORT="$port" \
MIRADOR_TOKEN_FILE="$token_file" \
python3 - <<'PY'
import base64
import hashlib
import http.client
import json
import os
import re
import socket
import struct
import subprocess
import sys
import time

host = os.environ["MIRADOR_VERIFY_HOST"]
port = int(os.environ["MIRADOR_VERIFY_PORT"])
with open(os.environ["MIRADOR_TOKEN_FILE"], "r", encoding="utf-8") as f:
    token = f.read().strip()

def request(method, path, headers=None, body=None, timeout=3):
    conn = http.client.HTTPConnection(host, port, timeout=timeout)
    conn.request(method, path, body=body, headers=headers or {})
    resp = conn.getresponse()
    data = resp.read()
    conn.close()
    return resp.status, data

def stream_lengths(seconds=4, byte_limit=30_000_000):
    s = socket.create_connection((host, port), timeout=3)
    s.sendall(f"GET /stream.mjpg?token={token} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
    s.settimeout(0.5)
    data = b""
    start = time.time()
    while time.time() - start < seconds and len(data) < byte_limit:
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            continue
        if not chunk:
            break
        data += chunk
    s.close()
    return [int(x) for x in re.findall(br"Content-Length: (\d+)", data)], len(data)

def read_ws_frame(sock, prebuffered):
    data = bytearray(prebuffered)

    def need(n):
        while len(data) < n:
            chunk = sock.recv(4096)
            if not chunk:
                return False
            data.extend(chunk)
        return True

    if not need(2):
        return None
    masked = (data[1] & 0x80) != 0
    length = data[1] & 0x7F
    offset = 2
    if length == 126:
        if not need(offset + 2):
            return None
        length = (data[offset] << 8) | data[offset + 1]
        offset += 2
    elif length == 127:
        if not need(offset + 8):
            return None
        length = int.from_bytes(data[offset:offset + 8], "big")
        offset += 8
    mask = b""
    if masked:
        if not need(offset + 4):
            return None
        mask = data[offset:offset + 4]
        offset += 4
    if not need(offset + length):
        return None
    payload = bytes(data[offset:offset + length])
    if masked:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return payload.decode("utf-8", "replace")


def ws_input_check(timeout=3):
    key = base64.b64encode(os.urandom(16)).decode()
    expected = base64.b64encode(
        hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
    ).decode()
    sock = socket.create_connection((host, port), timeout=timeout)
    sock.settimeout(timeout)
    handshake = (
        f"GET /ws/input?token={token} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    ).encode()
    sock.sendall(handshake)

    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
    header_blob, _, rest = buf.partition(b"\r\n\r\n")
    header_text = header_blob.decode("latin-1")
    handshake_101 = header_text.startswith("HTTP/1.1 101")
    accept_ok = f"sec-websocket-accept: {expected}".lower() in header_text.lower()

    payload = b'{"type":"pointerMove","x":0.5,"y":0.5,"buttons":0,"seq":4242}'
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    frame = bytearray([0x81])
    if len(payload) < 126:
        frame.append(0x80 | len(payload))
    else:
        frame.append(0x80 | 126)
        frame += struct.pack(">H", len(payload))
    frame += mask + masked
    sock.sendall(frame)

    ack = read_ws_frame(sock, rest)
    sock.close()
    ack_ok = ack is not None and '"type":"ack"' in ack and '"seq":4242' in ack
    return handshake_101, accept_ok, ack_ok


try:
    ws_handshake_101, ws_accept_ok, ws_ack_ok = ws_input_check()
except Exception as exc:  # noqa: BLE001 - report transport failure as a failed check
    ws_handshake_101, ws_accept_ok, ws_ack_ok = False, False, False
    print(f"ws_error={exc}")

service = f"gui/{os.getuid()}/com.mirador.host"
launch = subprocess.run(["launchctl", "print", service], text=True, capture_output=True)
listener = subprocess.run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN"], text=True, capture_output=True)

root_status, html = request("GET", f"/?token={token}")
html_text = html.decode("utf-8", "replace")
asset_status, css = request("GET", "/assets/viewer.css", headers={"X-Mirador-Token": token})
js_status, js = request("GET", "/assets/viewer.js", headers={"X-Mirador-Token": token})
js_text = js.decode("utf-8", "replace")
no_token_status, _ = request("GET", "/metrics")
metrics_status, metrics_bytes = request("GET", "/metrics", headers={"X-Mirador-Token": token})
text_status, text_body = request(
    "POST",
    "/input",
    headers={"X-Mirador-Token": token, "Content-Type": "application/json"},
    body=b'{"type":"text","text":"x"}',
)
pointer_status, pointer_body = request(
    "POST",
    "/input",
    headers={"X-Mirador-Token": token, "Content-Type": "application/json"},
    body=b'{"type":"pointerMove","x":0.5,"y":0.5,"buttons":0}',
)
lengths, stream_bytes = stream_lengths()
large_frames = sum(length > 1000 for length in lengths)
small_frames = sum(length <= 1000 for length in lengths)
try:
    metrics = json.loads(metrics_bytes)
except Exception:
    metrics = {}

checks = {
    "launchagent_running": launch.returncode == 0 and "state = running" in launch.stdout,
    "port_listening": listener.returncode == 0,
    "viewer_html_200": root_status == 200,
    "static_css_200": asset_status == 200 and b"100dvh" in css,
    "static_js_200": js_status == 200 and "touchstart" in js_text,
    "touch_controls_present": all(marker in (html_text + js_text) for marker in ["mobile-controls", "keyboard-button", "touchstart", "twoFingerScrollState"]),
    "ws_input_markers_present": all(marker in (html_text + js_text) for marker in ["/ws/input", "WebSocket", "sendInput", "transport-status"]),
    "auth_gate_401_without_token": no_token_status == 401,
    "metrics_200_with_token": metrics_status == 200,
    "input_ws_handshake_101": ws_handshake_101 and ws_accept_ok,
    "input_ws_ack": ws_ack_ok,
    "accessibility_text_204": text_status == 204,
    "accessibility_pointer_204": pointer_status == 204,
    "screen_recording_real_frames": large_frames > 0,
}

print("mirador live verification")
print(f"target=http://{host}:{port}")
print(f"pid_line={next((line for line in listener.stdout.splitlines() if 'mirador' in line), 'not-listening')}")
print(f"metrics={json.dumps(metrics, sort_keys=True)}")
print(f"stream_bytes={stream_bytes} frames={len(lengths)} large_frames={large_frames} small_frames={small_frames} first_lengths={lengths[:8]}")
print(f"input_text_status={text_status} input_pointer_status={pointer_status}")
if text_status != 204 and text_body:
    print("input_text_body=" + text_body.decode("utf-8", "replace"))
if pointer_status != 204 and pointer_body:
    print("input_pointer_body=" + pointer_body.decode("utf-8", "replace"))
print("checks:")
for name, ok in checks.items():
    print(f"  {'PASS' if ok else 'FAIL'} {name}")

if not all(checks.values()):
    sys.exit(1)
PY

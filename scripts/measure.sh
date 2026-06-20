#!/usr/bin/env bash
set -euo pipefail

# Repeatable performance harness for the Mac-host / browser-viewer loop.
# Drives synthetic pointer motion (which also exercises the capture path), while
# sampling /metrics and the MJPEG stream, then prints one summary block:
#   capture FPS, bitrate, dropped/incomplete frames, frame age, stream sent-FPS,
#   receive-age, and input dispatch + WebSocket ack round-trip latency.
#
# Usage: ./scripts/measure.sh            # ~10s run against 127.0.0.1:8787
#   MIRADOR_MEASURE_SECONDS=20 ./scripts/measure.sh

host="${MIRADOR_VERIFY_HOST:-127.0.0.1}"
port="${MIRADOR_VERIFY_PORT:-8787}"
seconds="${MIRADOR_MEASURE_SECONDS:-10}"
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
MIRADOR_MEASURE_SECONDS="$seconds" \
MIRADOR_TOKEN_FILE="$token_file" \
python3 - <<'PY'
import base64, hashlib, json, os, re, socket, struct, threading, time
import http.client

host = os.environ["MIRADOR_VERIFY_HOST"]
port = int(os.environ["MIRADOR_VERIFY_PORT"])
seconds = float(os.environ["MIRADOR_MEASURE_SECONDS"])
with open(os.environ["MIRADOR_TOKEN_FILE"], "r", encoding="utf-8") as f:
    token = f.read().strip()

def pct(values, p):
    if not values:
        return None
    s = sorted(values)
    k = min(len(s) - 1, max(0, int(round((p / 100.0) * (len(s) - 1)))))
    return s[k]

def fmt(v, suffix=""):
    return "n/a" if v is None else f"{v:.1f}{suffix}"

# ---- /metrics poller -------------------------------------------------------
metrics_samples = []
def poll_metrics(deadline):
    while time.time() < deadline:
        try:
            c = http.client.HTTPConnection(host, port, timeout=2)
            c.request("GET", "/metrics", headers={"X-Mirador-Token": token})
            r = c.getresponse(); body = r.read(); c.close()
            if r.status == 200:
                metrics_samples.append(json.loads(body))
        except Exception:
            pass
        time.sleep(0.5)

# ---- MJPEG stream reader (sent-FPS + receive-age) --------------------------
stream_stats = {"frames": 0, "seqs": set(), "ages": [], "elapsed": 0.0}
def read_stream(deadline):
    # Record each frame header's arrival time, then parse once. Frames are large
    # (~tens of KB), so we scan only the unparsed tail rather than truncating it.
    try:
        s = socket.create_connection((host, port), timeout=2)
        s.sendall(f"GET /stream.mjpg?token={token} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
        s.settimeout(0.5)
        header = re.compile(rb"X-Mirador-Sequence: (\d+)\r\nX-Mirador-Capture-Millis: (\d+)\r\nContent-Length: (\d+)")
        buf = bytearray(); scanned = 0; start = time.time()
        while time.time() < deadline:
            try:
                chunk = s.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                break
            now_ms = time.time() * 1000.0
            buf.extend(chunk)
            for m in header.finditer(buf, scanned):
                cap = int(m.group(2))
                stream_stats["frames"] += 1
                stream_stats["seqs"].add(int(m.group(1)))
                if cap > 0:
                    stream_stats["ages"].append(now_ms - cap)
                scanned = m.end()
            # keep an unparsed tail large enough to hold a split header line
            if scanned > 4096:
                del buf[:scanned - 256]
                scanned = 256
        stream_stats["elapsed"] = time.time() - start
        s.close()
    except Exception as exc:
        stream_stats["error"] = str(exc)

# ---- /ws/video reader (H.264 sent-FPS, bitrate, receive-age) ---------------
# Becomes a video consumer (so capture/encode start) and parses each binary frame's
# "seq(8) | captureMillis(8) | flags(1) | Annex-B" header.
video_stats = {"frames": 0, "bytes": 0, "ages": [], "keyframes": 0, "seqs": set(), "elapsed": 0.0}
def read_video(deadline):
    try:
        key = base64.b64encode(os.urandom(16)).decode()
        s = socket.create_connection((host, port), timeout=2); s.settimeout(0.5)
        s.sendall((f"GET /ws/video?token={token} HTTP/1.1\r\nHost: {host}\r\n"
                   "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                   f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        # Read and validate the handshake: a non-101 reply (401 auth, 503, redirect) must be
        # surfaced as an error, not silently parsed as video frames -> bogus "0 fps".
        hs = bytearray()
        while b"\r\n\r\n" not in hs:
            try:
                chunk = s.recv(4096)
            except socket.timeout:
                if time.time() >= deadline:
                    video_stats["error"] = "handshake timeout"; return
                continue
            if not chunk:
                video_stats["error"] = "handshake closed"; return
            hs.extend(chunk)
        head, _, rest = bytes(hs).partition(b"\r\n\r\n")
        status = head.split(b"\r\n", 1)[0].decode("latin1", "replace")
        if "101" not in status:
            video_stats["error"] = f"upgrade failed: {status}"; return
        # Server->client frames: unmasked binary (opcode 0x2). Parse with a read cursor so
        # consuming a frame is O(1) amortized (no per-frame buffer memmove), and read only the
        # 17-byte header rather than copying each multi-KB payload.
        data = bytearray(rest); pos = 0; start = time.time()
        def fill():
            try:
                chunk = s.recv(65536)
            except socket.timeout:
                return True
            if not chunk:
                return False
            data.extend(chunk)
            return True
        def have(n):
            while len(data) - pos < n:
                if time.time() >= deadline or not fill():
                    return False
            return True
        while time.time() < deadline:
            if not have(2):
                break
            opcode = data[pos] & 0x0F
            ln = data[pos + 1] & 0x7F; off = 2
            if ln == 126:
                if not have(off + 2): break
                ln = (data[pos + off] << 8) | data[pos + off + 1]; off += 2
            elif ln == 127:
                if not have(off + 8): break
                ln = struct.unpack(">Q", bytes(data[pos + off:pos + off + 8]))[0]; off += 8
            if not have(off + ln):
                break
            if opcode == 0x8:  # close
                break
            if opcode == 0x2 and ln >= 17:  # binary H.264 access unit
                base = pos + off
                seq = struct.unpack(">Q", bytes(data[base:base + 8]))[0]
                cap = struct.unpack(">Q", bytes(data[base + 8:base + 16]))[0]
                flags = data[base + 16]
                now_ms = time.time() * 1000.0
                video_stats["frames"] += 1
                video_stats["bytes"] += ln
                video_stats["seqs"].add(seq)
                if flags & 0x01:
                    video_stats["keyframes"] += 1
                if cap > 0:
                    video_stats["ages"].append(now_ms - cap)
            pos += off + ln
            if pos > (1 << 20):  # compact the consumed prefix occasionally
                del data[:pos]; pos = 0
        video_stats["elapsed"] = time.time() - start
        s.close()
    except Exception as exc:
        video_stats["error"] = str(exc)

# ---- WebSocket synthetic input (drives motion + measures ack RTT) ----------
ws_stats = {"sent": 0, "acked": 0, "rtts": []}
def ws_recv_frame(sock, pre):
    data = bytearray(pre)
    def need(n):
        while len(data) < n:
            c = sock.recv(4096)
            if not c:
                return False
            data.extend(c)
        return True
    if not need(2): return None, bytes(data)
    masked = (data[1] & 0x80) != 0; ln = data[1] & 0x7F; off = 2
    if ln == 126:
        if not need(off+2): return None, bytes(data)
        ln = (data[off] << 8) | data[off+1]; off += 2
    mask = b""
    if masked:
        if not need(off+4): return None, bytes(data)
        mask = data[off:off+4]; off += 4
    if not need(off+ln): return None, bytes(data)
    payload = bytes(data[off:off+ln])
    if masked:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return payload.decode("utf-8", "replace"), bytes(data[off+ln:])

def synthetic_input(deadline):
    try:
        key = base64.b64encode(os.urandom(16)).decode()
        s = socket.create_connection((host, port), timeout=2); s.settimeout(2)
        s.sendall((f"GET /ws/input?token={token} HTTP/1.1\r\nHost: {host}\r\n"
                   "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                   f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            buf += s.recv(4096)
        _, _, rest = buf.partition(b"\r\n\r\n")
        sent_at = {}
        leftover = {"b": rest}
        def reader():
            while time.time() < deadline + 1:
                try:
                    msg, leftover["b"] = ws_recv_frame(s, leftover["b"])
                except Exception:
                    return
                if msg is None:
                    return
                try:
                    j = json.loads(msg)
                except Exception:
                    continue
                if j.get("type") == "ack" and j.get("seq") in sent_at:
                    ws_stats["rtts"].append((time.time() - sent_at[j["seq"]]) * 1000.0)
                    ws_stats["acked"] += 1
        t = threading.Thread(target=reader, daemon=True); t.start()
        seq = 0
        while time.time() < deadline:
            seq += 1
            # sweep the pointer in a circle so the screen actually changes
            ang = seq * 0.2
            x = 0.5 + 0.35 * __import__("math").cos(ang)
            y = 0.5 + 0.35 * __import__("math").sin(ang)
            payload = json.dumps({"type": "pointerMove", "x": round(x, 4), "y": round(y, 4), "buttons": 0, "seq": seq}).encode()
            mask = os.urandom(4)
            masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            frame = bytearray([0x81])
            if len(payload) < 126:
                frame.append(0x80 | len(payload))
            else:
                frame.append(0x80 | 126); frame += struct.pack(">H", len(payload))
            frame += mask + masked
            sent_at[seq] = time.time()
            s.sendall(frame)
            ws_stats["sent"] += 1
            time.sleep(1.0 / 60.0)   # ~60 Hz
        time.sleep(0.3)
        s.close()
    except Exception as exc:
        ws_stats["error"] = str(exc)

deadline = time.time() + seconds
threads = [
    threading.Thread(target=poll_metrics, args=(deadline,)),
    threading.Thread(target=read_stream, args=(deadline,)),
    threading.Thread(target=read_video, args=(deadline,)),
    threading.Thread(target=synthetic_input, args=(deadline,)),
]
for t in threads: t.start()
for t in threads: t.join()

def col(key):
    return [s.get(key, 0) for s in metrics_samples if isinstance(s.get(key), (int, float))]

fps = col("fps"); bitrate = col("bitrateBitsPerSec"); age = col("latestFrameAgeMillis")
dispatch = col("inputDispatchMillis")
enc_fps = col("encodeFps"); enc_bitrate = col("encodeBitrateBitsPerSec")
enc_ms = col("encodeMillis"); kf_interval = col("keyframeIntervalFrames")
last = metrics_samples[-1] if metrics_samples else {}
sent_fps = (stream_stats["frames"] / stream_stats["elapsed"]) if stream_stats.get("elapsed") else 0.0
vid_fps = (video_stats["frames"] / video_stats["elapsed"]) if video_stats.get("elapsed") else 0.0
vid_kbit = (video_stats["bytes"] * 8.0 / video_stats["elapsed"] / 1000.0) if video_stats.get("elapsed") else 0.0

print("mirador performance harness")
print(f"target=http://{host}:{port}  window={seconds:.0f}s  metrics_samples={len(metrics_samples)}")
print("-- capture --")
print(f"  capture_fps      p50={fmt(pct(fps,50))} max={fmt(max(fps) if fps else None)}")
print(f"  bitrate_kbit_s   p50={fmt((pct(bitrate,50) or 0)/1000)} max={fmt((max(bitrate) if bitrate else 0)/1000)}")
print(f"  frame_age_ms     p50={fmt(pct(age,50),'ms')} max={fmt(max(age) if age else None,'ms')}")
print(f"  dropped/incomplete = {last.get('droppedFrames','?')}/{last.get('incompleteFrames','?')}")
print("-- encode (H.264) --")
print(f"  encode_fps       p50={fmt(pct(enc_fps,50))} max={fmt(max(enc_fps) if enc_fps else None)}")
print(f"  encode_kbit_s    p50={fmt((pct(enc_bitrate,50) or 0)/1000)} max={fmt((max(enc_bitrate) if enc_bitrate else 0)/1000)}")
print(f"  encode_ms        p50={fmt(pct(enc_ms,50),'ms')} max={fmt(max(enc_ms) if enc_ms else None,'ms')}")
print(f"  keyframe_interval_frames p50={fmt(pct(kf_interval,50))}")
print("-- video (H.264, /ws/video viewer side) --")
print(f"  sent_fps         {vid_fps:.1f}  frames={video_stats['frames']} distinct_seqs={len(video_stats['seqs'])} keyframes={video_stats['keyframes']}")
print(f"  wire_kbit_s      {vid_kbit:.1f}")
print(f"  receive_age_ms   p50={fmt(pct(video_stats['ages'],50),'ms')} p95={fmt(pct(video_stats['ages'],95),'ms')}")
print("-- stream (MJPEG fallback, viewer side) --")
print(f"  sent_fps         {sent_fps:.1f}  frames={stream_stats['frames']} distinct_capture_seqs={len(stream_stats['seqs'])}")
print(f"  receive_age_ms   p50={fmt(pct(stream_stats['ages'],50),'ms')} p95={fmt(pct(stream_stats['ages'],95),'ms')}")
print("-- input --")
print(f"  server_dispatch_ms p50={fmt(pct(dispatch,50),'ms')} max={fmt(max(dispatch) if dispatch else None,'ms')}")
print(f"  ws_ack_rtt_ms      p50={fmt(pct(ws_stats['rtts'],50),'ms')} p95={fmt(pct(ws_stats['rtts'],95),'ms')}  sent={ws_stats['sent']} acked={ws_stats['acked']}")
for label, st in (("stream", stream_stats), ("video", video_stats), ("ws", ws_stats)):
    if st.get("error"):
        print(f"  NOTE {label}_error={st['error']}")
PY

# mirador Measurements

## Baseline targets

- Idle RSS target: single-digit to low-tens of MB if practical.
- Idle CPU target: near zero when no viewer is connected.
- Active stream memory target: stable over time with bounded frame queues.

## Performance targets ("good real-time")

Proposed, adjustable bar for the LAN MJPEG POC (the WebRTC path, #2, raises these):

| Metric | Target (LAN) | Source |
| --- | --- | --- |
| Capture FPS (under motion) | ≥ 15 fps sustained | `/metrics` `fps` |
| Stream sent FPS (to a fast viewer) | ≥ 15 fps (match capture) | `measure.sh` `sent_fps` |
| Frame receive-age | p50 < ~150 ms | `measure.sh` `receive_age_ms` |
| Server input dispatch | < ~5 ms | `/metrics` `inputDispatchMillis` |
| WebSocket ack RTT (LAN) | p50 < ~30 ms | `measure.sh` `ws_ack_rtt_ms` |
| Motion-to-photon (stretch) | < ~100 ms | native/WebRTC client (#2) |

## Measurement harness

`./scripts/measure.sh` (default ~10s window; `MIRADOR_MEASURE_SECONDS=20` to extend)
drives a synthetic pointer sweep — which exercises the capture path — while sampling
`/metrics` and the MJPEG stream, then prints capture FPS, bitrate, drops, frame age,
stream sent-FPS, receive-age, server input dispatch, and WebSocket ack RTT. Repeatable;
exits non-zero if the service is unreachable.

### 2026-06-20 — first instrumented baseline (loopback, static headless desktop)

`./scripts/measure.sh` against `127.0.0.1:8787`, build with real capture/input metrics:

- capture_fps p50 **15.0** (hits the `minimumFrameInterval` cap under synthetic motion)
- bitrate ~**2.3 Mbit/s** at 15 fps (≈19 KB/frame, 1280×720 JPEG q0.62) — confirms MJPEG is
  bandwidth-heavy and motivates #2
- frame_age p50 ~**38 ms**; stream receive_age p50 ~**37 ms**, p95 ~**67 ms** (fresh)
- server input dispatch p50 **0.2 ms**, max ~**2 ms**
- WebSocket ack RTT p50 **0.9 ms**, p95 ~**3 ms**, 100% acked — input transport is effectively
  instant on loopback

**Finding — MJPEG send cadence bottleneck:** stream **sent_fps ≈ 4.7** despite 15 fps capture
(verified independently: ~89 KB/s raw, ~4.7 `--frame` boundaries/s). The viewer saw ~5 fps
even though capture was 15 fps. **Resolved** below.

### 2026-06-20 — send-cadence fix (4.7 → 15 fps)

Root cause: the frame send loop used a chained `DispatchQueue.asyncAfter(67 ms)`, but the
LaunchAgent ran as `ProcessType` `Standard`, so launchd **coalesced the daemon's timers to
~6 Hz** — a requested 33 ms timer actually fired every ~167 ms (measured), and the 67 ms loop
ran at ~210 ms/frame. Neither queue QoS nor a `.latencyCritical` activity assertion helped;
the launchd-level throttle dominated.

Fix:
- `launchd/com.mirador.host.plist`: `ProcessType = Interactive` — stops timer coalescing
  (33 ms timer now fires at ~33 ms; verified). Requires an `install` (plist change), not just
  `restart`.
- Replaced the asyncAfter chain with a per-stream **`DispatchSourceTimer`** (~30 fps tick,
  explicit leeway), decoupled from send completion with an in-flight guard.
- Bandwidth-smart: sends only newly captured frames; on a static screen it resends the last
  frame at most once/second (keepalive).

Result (loopback): under motion **sent_fps ≈ 15.1** (matches capture, up from 4.7); idle
(static screen) **sent_fps = 1.0** (keepalive only — negligible bandwidth); idle CPU 0.0%.
The viewer is now smooth at the full capture rate.

### 2026-06-20 — H.264/WebCodecs video path (issue #2)

Added a hardware H.264 pipeline alongside MJPEG: `ScreenCaptureKit → VTCompressionSession
(High profile, real-time, no B-frames, ~2s IDR) → /ws/video binary WebSocket → Safari
WebCodecs VideoDecoder → <canvas>`. Each binary WS frame is `seq(8) | captureMillis(8) |
flags(1) | Annex-B` (SPS/PPS prepended to every keyframe; the video timer gates the first
send on a keyframe so a decoder never starts mid-GOP). The viewer feature-detects
`VideoDecoder` and uses the MJPEG `<img>` only as a fallback (it is not started when the
canvas path is available).

Behaviour:
- **Idle = no capture.** Capture/encode no longer start at launch; a `CaptureCoordinator`
  ref-counts viewer streams (MJPEG + video) and starts the ScreenCaptureKit/VideoToolbox
  pipeline on the first connection, tearing it down after the last disconnect. Idle RSS ~12 MB;
  active (single H.264 viewer) ~39 MB.
- Capture at 30 fps (`minimumFrameInterval = 1/30`), native 1080p.
- The capture callback only runs the encoder a viewer is watching (`CaptureConsumers`), so a
  pure H.264 session does no JPEG work.

New `/metrics` fields: `encodeFps`, `encodeBitrateBitsPerSec`, `encodeMillis`,
`keyframeIntervalFrames`, `videoStreams`.

#### CRITICAL: WebCodecs requires a secure context (HTTPS)
`VideoDecoder` is exposed but **`configure()` fails over plain `http://` on a LAN IP** — only
`localhost`/`127.0.0.1` count as secure over HTTP. On the phone over `http://192.168.1.149` the
decode silently fell back to MJPEG. **Fix: serve over HTTPS via Tailscale Serve**
(`tailscale serve 8787` → `https://arnabs-mac-mini.tailb3dd58.ts.net/`), which gives an
iOS-trusted cert and a secure origin. WebRTC would have the same requirement, so this is not
WebCodecs-specific. Also note Safari needs **avcC** (length-prefixed NAL units + an SPS/PPS
`description`), not Annex-B — the viewer converts on the client.

#### On-device result (2026-06-20, iPad, Tailscale HTTPS)
- WebCodecs hardware-decodes 1080p continuously: `chunks≈outputs`, `decodeQueueSize=0`,
  `codec=avc1.640029` (High, level 4.1). Canvas swap confirmed (`imgDisp=none canvasDisp=block`).
- `mjpeg=0 video=1` once the canvas takes over — single stream, no double-encode.
- Bitrate: ~0.02–0.3 Mbit/s on a near-static screen (vs MJPEG ~40 Mbit/s at 1080p) — H.264 is
  dramatically leaner. Encode latency ~5–9 ms/frame.
- Latency/load-time: subjectively good; initial (keyframe) sharpness good.
- **Quality under motion:** the rate controller initially softened text ("good for a few seconds
  then drops"). Fixed with High profile, 30 Mbit/s ceiling (`MIRADOR_H264_BITRATE_KBPS`), and a
  quality floor `MaxAllowedFrameQP=26` (`MIRADOR_H264_MAX_QP`). User-confirmed readable during
  interaction at QP 26.

#### 2026-06-20 — video-path harness baseline (loopback, synthetic motion)

`scripts/measure.sh` now also drives a `/ws/video` reader and reports the H.264 path
(`encode_fps/kbit_s/ms`, `keyframe_interval`, video `sent_fps`, wire kbit/s, `receive_age`).
Baseline at QP 26, 1080p30, synthetic pointer sweep:

| Metric | H.264 (/ws/video) | MJPEG (/stream.mjpg) |
| --- | --- | --- |
| fps | 29.5 | 28.9 |
| wire bitrate | ~10 Mbit/s (under motion) | ~64 Mbit/s |
| receive-age p50 / p95 | 7.3 / 12.4 ms | 17.9 / 32.0 ms |
| encode latency | ~8.5 ms/frame | — |
| keyframe interval | ~59 frames (~2s) | — |

H.264 is ~6.5× leaner than MJPEG at equal fps/resolution under motion, and far leaner
(~0.1 vs ~40 Mbit/s) on a static screen. Input dispatch p50 0.2 ms, WS ack RTT p50 0.8 ms.

**QP sweep was inconclusive** (QP 22/26/30 all ~7.8–8.7 Mbit/s, within noise): the synthetic
"circling cursor" motion changes too few pixels for the QP cap to bind. QP only matters under
large-area change (scrolling text, window drags), which can't be driven synthetically without an
app-specific scroll target — so QP-for-legibility is a real-motion/subjective test. QP 26 is the
validated default; lower (22) for sharper text at higher motion bitrate, raise (30+) for
leaner/remote. HEVC (spec open question) deferred: H.264 already beats MJPEG by ~6.5× and Safari
WebCodecs HEVC support is less mature; revisit if remote/cellular bitrate becomes a constraint.

## Input transport

The viewer sends input over a persistent WebSocket (`/ws/input`) and falls back to
one-POST-per-event HTTP (`/input`) when the socket is not open. Each event carries a
client `seq`; the server replies with `{"type":"ack","seq":N,"ok":bool}` so the viewer can
show transport health and last round-trip dispatch latency (header `transport-status`).
`/metrics` reports `inputSockets` (active WS input connections) and `inputEvents` (total
events dispatched over WS).

### 2026-06-19 — WebSocket input transport local verification

- git branch: `feat/websocket-input-transport`
- build/tests: `swift build` clean; `swift test` 61/61 pass (15 new: WS codec, seq decode,
  metrics fields, viewer markers).
- live loopback check against the debug binary on `127.0.0.1:8799`:
  - `GET /ws/input` handshake → `HTTP/1.1 101 Switching Protocols`, `Sec-WebSocket-Accept`
    matches RFC 6455.
  - masked client text frame `{"type":"pointerMove",…,"seq":4242}` → server ack
    `{"type":"ack","seq":4242,"ok":true}`.
  - `?token=wrong` upgrade → `401 Unauthorized` (auth gate enforced on the WS path).
  - `/metrics` reported `inputEvents:1` after one dispatched event; `inputSockets:0` once the
    socket closed.
- pending: browser end-to-end latency numbers and on-device iPhone/iPad WS verification after
  the new build is deployed.

## Runs

Record each test run here with:

- date/time
- git commit
- network path: LAN or Tailscale/VPN
- viewer device/browser
- idle RSS
- active RSS
- CPU
- FPS
- dropped frames
- subjective notes

### 2026-06-14 18:26:56 PDT — runnable POC server smoke test

- git commit: this Task 6 commit (`feat: wire runnable poc server`)
- network path: loopback (`127.0.0.1:8787`), server bound by `./scripts/run-dev.sh` to `0.0.0.0:8787`
- viewer device/browser: curl smoke checks
- idle RSS: 10,384 KiB via `ps -axo pid,ppid,rss,command` for `.build/arm64-apple-macosx/debug/mirador`; `/metrics` reported `rssBytes=10190848`
- active RSS: not measured; `/stream.mjpg` smoke test used a short 1 second curl timeout
- CPU: not measured
- FPS: 0 (real capture not wired; synthetic JPEG fallback stream)
- dropped frames: 0
- subjective notes: `/metrics` returned JSON with required fields; `/` returned HTTP 200 HTML; `/missing` returned 404; `/stream.mjpg` began multipart MJPEG with a bounded synthetic 1x1 JPEG frame.

### 2026-06-14 18:45:46 PDT — release POC baseline measurement

- git commit: pre-report HEAD `3f17288a193ecfba6cd22e3dfb30f52b100ca666` on branch `feat/poc-baseline`
- build: `swift build -c release` succeeded; verified executable `.build/release/mirador` exists (`Mach-O 64-bit executable arm64`)
- network path: loopback (`http://127.0.0.1:8787/`) and Mac-side LAN URL (`http://192.168.1.149:8787/`); server bound to `0.0.0.0:8787`; no port deviation
- viewer device/browser: curl from this Mac; physical iPad validation pending
- idle RSS: 10,368 KiB via `ps -o pid,ppid,rss,pcpu,command -p 13856` for `.build/release/mirador`; `/metrics` reported `rssBytes=10338304` (~9.86 MiB)
- active RSS: not measured as a sustained viewer session; `/stream.mjpg` was sampled with a 2 second curl timeout and returned 1,095 bytes
- CPU: 0.0% idle via `ps`; no sustained active-stream CPU measured
- FPS: 0 from `/metrics` (real ScreenCaptureKit frames are not active in this POC run; synthetic MJPEG fallback stream)
- dropped frames: 0 from `/metrics`
- route checks:
  - `/`: HTTP 200, `Content-Type: text/html; charset=utf-8`, `Content-Length: 1090`, loopback and LAN both loaded 1,090 bytes
  - `/metrics`: `{"activeStreams":0,"droppedFrames":0,"fps":0,"rssBytes":10338304}`
  - `/stream.mjpg`: HTTP 200, `Content-Type: multipart/x-mixed-replace; boundary=frame`; body began `--frame` with JPEG bytes
  - `/missing`: HTTP 404, 9 byte body
- subjective notes: release server plumbing is reliable from local curl and Mac-side LAN URL. Idle memory and CPU are low. Physical iPad loading and real ScreenCaptureKit streaming/smoothness remain pending.

### 2026-06-14 18:51:58 PDT — release synthetic active-stream and shutdown check

- git commit: Task 8 review base `735e040b92a8ee54803d33fea88b68b8bec769a3` plus local clean-shutdown fixes before final commit
- build: `swift build -c release` succeeded; executable `.build/release/mirador` rebuilt
- network path: loopback (`http://127.0.0.1:8787/`); server bound to `0.0.0.0:8787`
- viewer device/browser: curl held `/stream.mjpg` open for 10 seconds (`--max-time 10`) to exercise the synthetic MJPEG stream
- idle RSS: `/metrics` before active stream reported `rssBytes=9977856` (~9.52 MiB)
- active RSS: `/metrics` during stream reported `rssBytes=10567680` (~10.08 MiB); late sample reported `rssBytes=10682368` (~10.19 MiB)
- CPU: five `ps -o pid=,rss=,pcpu= -p 15364` samples during streaming all reported `0.0%` CPU; `ps` RSS samples were 2,176 KiB while `/metrics` reported the resident footprint above
- FPS: 0 from `/metrics` (synthetic fallback stream, real ScreenCaptureKit frames not active)
- active streams: `/metrics` reported `activeStreams=1` while curl held `/stream.mjpg` open; `activeStreams=0` after curl timed out
- dropped frames: 0 from `/metrics`
- stream bytes: curl received 5,475 bytes before the intentional 10 second timeout (`curl: (28) Operation timed out after 10137 milliseconds with 5475 bytes received`)
- shutdown verification: server received SIGTERM, printed `Received SIGTERM; shutting down.`, exited without `SWIFT TASK CONTINUATION MISUSE`, and no `mirador` process or listener on TCP/8787 remained afterward
- subjective notes: synthetic active-stream memory stayed in the low-MiB range and CPU remained effectively idle on the Mac. Physical iPad Safari playback remains pending.

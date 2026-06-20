# mirador POC Report

## Summary

The release POC server builds and runs successfully as a measured background process bound to `0.0.0.0:8787`. Local and Mac-side LAN HTTP checks from the Mac loaded the viewer page, `/metrics` reported low idle memory, and the MJPEG stream endpoint produced a multipart response with synthetic JPEG frame bytes. Physical iPad Safari validation and real ScreenCaptureKit streaming remain pending and must be completed by Arnab on the target device before claiming end-to-end display quality.

## Environment

- Date/time: 2026-06-14 18:51:58 PDT
- Host: Arnabs-Mac-mini.local
- OS: macOS 26.5.1 (Build 25F80), Darwin 25.5.0, arm64
- Swift: Apple Swift 6.2.3 (`swift-driver` 1.127.14.1), target `arm64-apple-macosx26.0`
- Branch: `feat/poc-baseline`
- Baseline commit measured: `3f17288a193ecfba6cd22e3dfb30f52b100ca666`
- Task 8 review-fix base commit: `735e040b92a8ee54803d33fea88b68b8bec769a3`
- Binary: `.build/release/mirador` (`Mach-O 64-bit executable arm64`)
- Server command: `.build/release/mirador --host 0.0.0.0 --port 8787`
- Measurement process: PID 13856 for the actual release binary; parent shell PID 13853
- Network URLs tested from this Mac: `http://127.0.0.1:8787/` and `http://192.168.1.149:8787/`

## Results

- Idle RSS: 10,368 KiB from `ps`; `/metrics` reported `rssBytes=10338304` (~9.86 MiB)
- Idle CPU: 0.0% from `ps -o pid,ppid,rss,pcpu,command -p 13856`
- Viewer load result: PASS from this Mac on loopback and LAN URL; both returned HTTP 200 HTML with `Content-Length: 1090`
- Stream result: PASS for endpoint plumbing; `/stream.mjpg` returned HTTP 200 with `Content-Type: multipart/x-mixed-replace; boundary=frame`, began with `--frame`, and included JPEG bytes. The 2 second sample downloaded 1,095 bytes before curl timed out intentionally.
- Sustained synthetic stream result: PASS for Mac-side synthetic active-stream plumbing; curl held `/stream.mjpg` open for 10 seconds, `/metrics` reported `activeStreams=1` during the stream and `activeStreams=0` afterward, RSS stayed around 10 MiB via `/metrics`, CPU samples were 0.0%, and 5,475 bytes were downloaded before the intentional timeout.
- Metrics result: PASS; `/metrics` returned `{"activeStreams":0,"droppedFrames":0,"fps":0,"rssBytes":10338304}`
- Missing route result: PASS; `/missing` returned HTTP 404 with a 9 byte body
- Shutdown result: PASS; SIGTERM cleanly stopped the HTTP server and capture service, emitted `Received SIGTERM; shutting down.`, left no `mirador` process or TCP/8787 listener, and did not emit `SWIFT TASK CONTINUATION MISUSE`.
- Subjective smoothness: not physically validated. The stream plumbing emits synthetic MJPEG fallback frames in this run, so real ScreenCaptureKit smoothness and iPad Safari playback quality remain pending.

## Decision

Proceed to the WebRTC/H.264 next phase after Arnab completes a physical iPad Safari check. The release POC is low-memory at idle and during a synthetic active stream, CPU is effectively zero in Mac-side automated checks, shutdown is clean, and the HTTP viewer/metrics/MJPEG plumbing is reliable from local and Mac-side LAN checks. This decision is limited to baseline service plumbing until physical iPad validation and real ScreenCaptureKit streaming performance are complete.

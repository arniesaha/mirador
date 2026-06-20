# Mirador native client (iOS / iPadOS)

Universal SwiftUI viewer for the mirador macOS service. Connects to `/ws/video` (hardware H.264
decode via `AVSampleBufferDisplayLayer`) and `/ws/input` (touch / trackpad / keyboard), over plain
`ws://` — native decode has no WebCodecs secure-context requirement, so it can hit the Mac directly
on the LAN/Tailscale for lowest latency.

## Build

The Xcode project is generated from `project.yml` with [XcodeGen] (it is gitignored). **Re-run
`xcodegen generate` after adding/removing source files.**

```sh
brew install xcodegen           # one-time
cd clients/Mirador
xcodegen generate               # writes Mirador.xcodeproj
open Mirador.xcodeproj      # or build from CLI below
```

Simulator build:

```sh
xcodebuild -project Mirador.xcodeproj -scheme Mirador -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

Device build: open in Xcode, set your Development Team (Signing & Capabilities), pick your iPhone/
iPad, and Run.

## Connecting

Enter the Mac's host (LAN IP `192.168.1.149`, or its Tailscale name), port `8787`, and the token
from `~/.mirador-token` on the Mac. Fields persist between launches.

Automation / simulator launch can auto-connect via environment variables:

```sh
SIMCTL_CHILD_MIRADOR_AUTOCONNECT=1 SIMCTL_CHILD_MIRADOR_HOST=127.0.0.1 \
SIMCTL_CHILD_MIRADOR_PORT=8787 SIMCTL_CHILD_MIRADOR_TOKEN="$(cat ~/.mirador-token)" \
xcrun simctl launch booted com.mirador.client
```

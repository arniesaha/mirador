#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift run mirador --host 0.0.0.0 --port 8787

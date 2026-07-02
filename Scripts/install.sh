#!/usr/bin/env bash
set -euo pipefail

# Build and install "Time Tracker.app" into /Applications.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/Scripts/build.sh" --install

#!/usr/bin/env bash
set -euo pipefail

# Health check for mpv audio stream
# Checks if mpv is playing audio via IPC socket, restarts if not.
# Optionally sends a heartbeat ping when the stream is healthy.
#
# Usage: health-check.sh [heartbeat-url]

HEARTBEAT_URL="${1:-}"
IPC_SOCKET="/tmp/mpv-audio.sock"

# Check if IPC socket exists
if [ ! -S "$IPC_SOCKET" ]; then
  systemctl --user restart mpv-stream
  exit 0
fi

# Query mpv for playback time via IPC
RESPONSE=$(echo '{"command":["get_property","playback-time"]}' | socat - "$IPC_SOCKET" 2>/dev/null || true)

# Check if we got a valid response with data (not an error)
if [ -z "$RESPONSE" ] || echo "$RESPONSE" | jq -e '.error != "success"' > /dev/null 2>&1; then
  systemctl --user restart mpv-stream
  exit 0
fi

# Stream is healthy — send heartbeat if configured
if [ -n "$HEARTBEAT_URL" ]; then
  curl -fsI "$HEARTBEAT_URL" > /dev/null 2>&1 || true
fi

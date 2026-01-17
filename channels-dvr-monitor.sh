#!/bin/bash
set -euo pipefail

CONTAINER="channels-dvr"
LOCKFILE="/run/channels-backup/.channels-backup.lock"
LOGFILE="/dev/shm/channels-monitor.log"

timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

# If backup is running, do nothing
if [ -f "$LOCKFILE" ]; then
    echo "$(timestamp) - Backup lockfile present, skipping monitor actions" >> "$LOGFILE"
    exit 0
fi

# Check if container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "$(timestamp) - ${CONTAINER} not running, attempting start" >> "$LOGFILE"
    docker start "$CONTAINER" >> "$LOGFILE" 2>&1 || \
        echo "$(timestamp) - ERROR: Failed to start ${CONTAINER}" >> "$LOGFILE"
    exit 0
fi

# Optional: check if container exists but is stopped
if docker ps -a --format '{{.Names}} {{.Status}}' | grep -q "^${CONTAINER} Exited"; then
    echo "$(timestamp) - ${CONTAINER} exists but is stopped, starting" >> "$LOGFILE"
    docker start "$CONTAINER" >> "$LOGFILE" 2>&1 || \
        echo "$(timestamp) - ERROR: Failed to start ${CONTAINER}" >> "$LOGFILE"
    exit 0
fi

# Optional: health check (HTTP)
if ! curl -fs --max-time 2 http://127.0.0.1:8089 >/dev/null; then
    echo "$(timestamp) - ${CONTAINER} unresponsive, restarting" >> "$LOGFILE"
    docker restart "$CONTAINER" >> "$LOGFILE" 2>&1 || \
        echo "$(timestamp) - ERROR: Failed to restart ${CONTAINER}" >> "$LOGFILE"
    exit 0
fi

echo "$(timestamp) - ${CONTAINER} healthy" >> "$LOGFILE"

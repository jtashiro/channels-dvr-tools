#!/bin/bash
set -euo pipefail

TARGET="nas.local"
SOURCE="$(hostname -s).local"
NAS_BASE="/mnt/cloud/CHANNELS_DVR_BACKUP"
CHANNELS_DATA="/mnt/cloud/channels-data"
DRY="${1:-}"

echo "============= BACKUP STARTED $(date) ==============="

###############################################
# Check if Channels DVR container is running
###############################################
is_running() {
    docker ps --format '{{.Names}}' | grep -q '^channels-dvr$'
}

###############################################
# Wait for Channels DVR to be idle (max 5 min)
###############################################
wait_for_idle() {
    local timeout=300   # 5 minutes
    local interval=30   # check every 30 seconds
    local waited=0

    echo "Checking Channels DVR idle state..."

    while true; do
        # If container is not running → treat as idle
        if ! is_running; then
            echo "Channels DVR container is not running — treating as idle"
            return 0
        fi

        # Container is running → check API
        BUSY=$(curl -s http://localhost:8089/dvr | jq -r '.busy' || echo "curl_failed")

        if [[ "$BUSY" == "false" ]]; then
            echo "Channels DVR is idle — proceeding with backup"
            return 0
        fi

        if (( waited >= timeout )); then
            echo "ABORT: Channels DVR remained busy/unreachable for 5 minutes — backup cancelled"
            return 1
        fi

        echo "Channels DVR busy or API unreachable — waiting ${interval}s..."
        sleep $interval
        waited=$(( waited + interval ))
    done
}

###############################################
# MAIN EXECUTION
###############################################

if ! wait_for_idle; then
    echo "Backup aborted due to timeout."
    exit 1
fi

echo "Stopping Channels DVR..."
docker stop channels-dvr
sleep 5

TS=$(date +"%Y-%m-%d_%H-%M-%S")
TARFILE="/tmp/channels-dvr-backup_${TS}.tar.gz"

echo "Creating tar archive (config/state only): $TARFILE"
tar --one-file-system -czf "$TARFILE" -C /opt channels-dvr

echo "Copying tar to NAS..."
scp $DRY "$TARFILE" "${TARGET}:${NAS_BASE}/${SOURCE}/"

echo "Removing local tar..."
rm -f "$TARFILE"

echo "Pruning old tar backups on NAS (keeping last 5)..."
ssh "$TARGET" "cd '${NAS_BASE}/${SOURCE}' && \
    ls -1t channels-dvr-backup_*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f"

echo "Mirroring /opt/channels-dvr to NAS via rsync..."
rsync -avh --delete $DRY /opt/channels-dvr/ \
    "${TARGET}:${NAS_BASE}/${SOURCE}/channels-dvr"

echo "Restarting Channels DVR..."
docker start channels-dvr

echo "Mirroring channels-data to NAS via rsync..."
rsync -avh --delete $DRY "${CHANNELS_DATA}/" \
    "${TARGET}:${NAS_BASE}/${SOURCE}/channels-data"

echo "============= BACKUP COMPLETED $(date) ==============="

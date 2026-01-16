#!/bin/bash

TARGET=nas.local
SOURCE=$(hostname -s).local
DRY=${1}

#!/bin/bash

while true; do
    BUSY=$(curl -s http://localhost:8089/dvr | jq -r '.busy')
    if [[ "$BUSY" == "false" ]]; then
        echo "Channels DVR is idle — proceeding with backup"
        break
    fi
    echo "Channels DVR busy — waiting 60 seconds..."
    sleep 60
done

docker stop channels-dvr
rsync -avh --delete $DRY /opt/channels-dvr/ "${TARGET}:/mnt/cloud/CHANNELS_DVR_BACKUP/${SOURCE}/channels-dvr"
docker start channels-dvr


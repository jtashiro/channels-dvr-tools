#!/bin/bash
set -euo pipefail
export PATH=$PATH:/usr/bin

MEDIA_USER="media"
MEDIA_GROUP="media"
MEDIA_ROOT="/mnt/cloud"
NAS_IP="${NAS_IP:-192.168.1.30}"
username="${YOURUSER:-media}"
password="${YOURPASS:-changeme}"
domain="WORKGROUP"
###############################################

HOSTNAME_LOCAL="$(hostname -s).local"
HOST_IP=$(hostname -I | awk '{print $1}')
DVRHOSTNAME_LOCAL="dvr-$(hostname -s).local"


banner() {
  echo "==========================================="
  echo "=== $* "
  echo "==========================================="
  echo
}
 
banner "Starting DVR Stack Installation"
banner "Ensure you have configured NAS_IP, username, password, and domain variables in the script."
banner "Validate that the MEDIA_USER ($MEDIA_USER) exists on this system."
if [[ "$(id -un)" != "$MEDIA_USER" ]]; then
  echo "ERROR: Must run as user '$MEDIA_USER'. Current user: '$(id -un)'."
  exit 1
fi


# If $MEDIA_ROOT does not exist, create it as root
if [[ ! -d "$MEDIA_ROOT" ]]; then
  echo "$MEDIA_ROOT does not exist, creating as root..."
  sudo mkdir -p "$MEDIA_ROOT"
  sudo chown "$MEDIA_USER:$MEDIA_GROUP" "$MEDIA_ROOT"
fi

banner "Checking for DNSMASQ service for container DNS configuration"
# DNSMASQ_IP for custom DNS
if pgrep dnsmasq >/dev/null 2>&1; then
  HOST_IP=$(hostname -I | awk '{print $1}')
  DNSMASQ_IP="$HOST_IP"
  echo "dnsmasq detected, using host IP $DNSMASQ_IP for container DNS."
else
  DNSMASQ_IP="${DNSMASQ_IP:-192.168.1.1}"
  echo "dnsmasq not detected, using default DNS $DNSMASQ_IP for containers."
fi

###############################################
# DIRECTORY STRUCTURE
###############################################
banner "=== Ensuring directory structure under $MEDIA_ROOT ==="

sudo mkdir -p \
  "$MEDIA_ROOT/channels-data" \
  "$MEDIA_ROOT/downloads/tv-sonarr" \
  "$MEDIA_ROOT/downloads/radarr" \
  "$MEDIA_ROOT/downloads/watch" \
  "$MEDIA_ROOT/downloads/incomplete" \
  "$MEDIA_ROOT/tv" \
  "$MEDIA_ROOT/movies" \
  "$MEDIA_ROOT/jackett-config" \
  "$MEDIA_ROOT/sonarr-config" \
  "$MEDIA_ROOT/radarr-config"

sudo chown -R "$MEDIA_USER:$MEDIA_GROUP" "$MEDIA_ROOT"

###############################################
# CIFS MOUNTS + SMB CREDENTIALS + FSTAB
###############################################
banner "=== Configuring CIFS mountpoints and fstab entries ==="

sudo mkdir -p /mnt/cloud-nas /mnt/cloud2-nas
sudo chown "$MEDIA_USER:$MEDIA_GROUP" /mnt/cloud-nas /mnt/cloud2-nas

if [[ ! -f /etc/smb-cred ]]; then
  echo "Creating /etc/smb-cred (edit manually)..."
  sudo tee /etc/smb-cred >/dev/null <<EOF
username=$username
password=$password
domain=$domain
EOF
  sudo chmod 600 /etc/smb-cred
fi

if ! grep -q "cloud-nas" /etc/fstab; then
  sudo tee -a /etc/fstab >/dev/null <<EOF

# Parent CIFS shares - add noserverino + cache=loose for safety
//$NAS_IP/cloud  /mnt/cloud-nas  cifs  credentials=/etc/smb-cred,vers=3.1.1,uid=1001,gid=1001,nofail,x-systemd.automount,x-systemd.idle-timeout=30,_netdev,noserverino,cache=loose 0 0
//$NAS_IP/cloud2 /mnt/cloud2-nas cifs  credentials=/etc/smb-cred,vers=3.1.1,uid=1001,gid=1001,nofail,x-systemd.automount,x-systemd.idle-timeout=30,_netdev,noserverino,cache=loose 0 0

EOF
fi

# Only create /mnt/cloud/plexserver symlink if it does not exist
if [ ! -L /mnt/cloud/plexserver ] && [ ! -e /mnt/cloud/plexserver ]; then
  sudo ln -s /mnt/cloud-nas/plexserver/ /mnt/cloud/plexserver
else
  echo "/mnt/cloud/plexserver already exists, not creating symlink."
fi

sudo systemctl daemon-reload
sudo mount -a || echo "WARNING: CIFS mounts may not be available until network is up."

###############################################
# BASE DEPENDENCIES
###############################################
banner "Installing base dependencies"
sudo apt update
sudo apt install -y curl wget jq ca-certificates gnupg software-properties-common cifs-utils netatalk

###############################################
# NETATALK CONFIG
###############################################
banner "Configuring Netatalk (AFP)"

sudo mkdir -p /etc/netatalk

sudo tee /etc/netatalk/afp.conf >/dev/null <<EOF
[Homes]
basedir regex = /home
follow symlinks = yes

[cloud-dvr]
path = /mnt/cloud
follow symlinks = yes
unix priv = yes
file perm = 0644
directory perm = 0755
EOF

sudo systemctl enable netatalk
sudo systemctl restart netatalk

###############################################
# ENABLE USER NAMESPACES (TVE)
###############################################
banner "Enabling unprivileged user namespaces"
echo "kernel.unprivileged_userns_clone=1" | sudo tee /etc/sysctl.d/99-userns.conf >/dev/null
sudo sysctl --system >/dev/null || echo "WARNING: sysctl reload failed."

###############################################
# INSTALL DOCKER ENGINE
###############################################
banner "Installing Docker Engine"

sudo apt remove -y docker docker-engine docker.io containerd runc || true

sudo apt update
sudo apt install -y ca-certificates curl gnupg

sudo install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
fi
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "=== Adding media user to docker group ==="
sudo usermod -aG docker "$MEDIA_USER" || true

echo "=== Refreshing docker group membership for this session ==="
newgrp docker <<EOF
echo "Docker group activated."
EOF

###############################################
# TRANSMISSION (native)
###############################################
banner "Installing Transmission"

if ! dpkg -s transmission-daemon >/dev/null 2>&1; then
  sudo apt install -y transmission-daemon
fi

sudo systemctl stop transmission-daemon || true

TRANSMISSION_CONFIG="/etc/transmission-daemon/settings.json"

# Create hard link for Transmission config in user config directory
USER_HOME="/home/$MEDIA_USER"
USER_CONFIG_DIR="$USER_HOME/.config/transmission-daemon"

# Ensure $USER_CONFIG_DIR exists and set ownership/permissions
if [[ ! -d "$USER_CONFIG_DIR" ]]; then
  sudo mkdir -p "$USER_CONFIG_DIR"
fi
sudo chown -R "$MEDIA_USER:$MEDIA_GROUP" "$USER_CONFIG_DIR"
sudo chmod 755 "$USER_CONFIG_DIR"

# Write static settings.json as provided by user
cat <<'EOF' | sudo tee $TRANSMISSION_CONFIG >/dev/null
{
  "alt-speed-down": 50,
  "alt-speed-enabled": false,
  "alt-speed-time-begin": 540,
  "alt-speed-time-day": 127,
  "alt-speed-time-enabled": false,
  "alt-speed-time-end": 1020,
  "alt-speed-up": 50,
  "announce-ip": "",
  "announce-ip-enabled": false,
  "anti-brute-force-enabled": false,
  "anti-brute-force-threshold": 100,
  "bind-address-ipv4": "0.0.0.0",
  "bind-address-ipv6": "::",
  "blocklist-enabled": false,
  "blocklist-url": "http://www.example.com/blocklist",
  "cache-size-mb": 4,
  "default-trackers": "",
  "dht-enabled": true,
  "download-dir": "/mnt/cloud/downloads",
  "download-limit": 100,
  "download-limit-enabled": 0,
  "download-queue-enabled": true,
  "download-queue-size": 15,
  "encryption": 1,
  "idle-seeding-limit": 0,
  "idle-seeding-limit-enabled": true,
  "incomplete-dir": "/mnt/cloud/downloads/incomplete",
  "incomplete-dir-enabled": true,
  "lpd-enabled": false,
  "max-peers-global": 200,
  "message-level": 2,
  "peer-congestion-algorithm": "",
  "peer-id-ttl-hours": 6,
  "peer-limit-global": 200,
  "peer-limit-per-torrent": 50,
  "peer-port": 60875,
  "peer-port-random-high": 65535,
  "peer-port-random-low": 49152,
  "peer-port-random-on-start": true,
  "peer-socket-tos": "le",
  "pex-enabled": true,
  "port-forwarding-enabled": true,
  "preallocation": 1,
  "prefetch-enabled": true,
  "queue-stalled-enabled": true,
  "queue-stalled-minutes": 30,
  "ratio-limit": 0,
  "ratio-limit-enabled": true,
  "rename-partial-files": true,
  "rpc-authentication-required": true,
  "rpc-bind-address": "0.0.0.0",
  "rpc-enabled": true,
  "rpc-host-whitelist": "127.0.0.1,192.168.1.*",
  "rpc-host-whitelist-enabled": false,
  "rpc-password": "{7ac83ea6fd492020b7d5eb7c56e1ec69d30436f3sLShkFQU",
  "rpc-port": 9091,
  "rpc-socket-mode": "0750",
  "rpc-url": "/transmission/",
  "rpc-username": "transmission",
  "rpc-whitelist": "127.0.0.1,192.168.1.*",
  "rpc-whitelist-enabled": false,
  "scrape-paused-torrents-enabled": true,
  "script-torrent-added-enabled": false,
  "script-torrent-added-filename": "",
  "script-torrent-done-enabled": false,
  "script-torrent-done-filename": "",
  "script-torrent-done-seeding-enabled": false,
  "script-torrent-done-seeding-filename": "",
  "seed-queue-enabled": false,
  "seed-queue-size": 0,
  "speed-limit-down": 100,
  "speed-limit-down-enabled": false,
  "speed-limit-up": 0,
  "speed-limit-up-enabled": true,
  "start-added-torrents": true,
  "tcp-enabled": true,
  "torrent-added-verify-mode": "fast",
  "trash-original-torrent-files": false,
  "umask": "002",
  "upload-limit": 0,
  "upload-limit-enabled": true,
  "upload-slots-per-torrent": 0,
  "utp-enabled": true,
  "watch-dir": "/mnt/cloud/downloads/watch",
  "watch-dir-enabled": true
}
EOF
sudo rm -f "$USER_CONFIG_DIR/settings.json"
sudo ln $TRANSMISSION_CONFIG "$USER_CONFIG_DIR/settings.json"
sudo chown "$MEDIA_USER:$MEDIA_GROUP" "$TRANSMISSION_CONFIG" "$USER_CONFIG_DIR/settings.json"
sudo chown -R "$MEDIA_USER:$MEDIA_GROUP" "$MEDIA_ROOT/downloads"  || true
sudo chown -R "$MEDIA_USER:$MEDIA_GROUP" /var/lib/transmission-daemon 2>/dev/null || true

sudo mkdir -p /etc/systemd/system/transmission-daemon.service.d
sudo tee /etc/systemd/system/transmission-daemon.service.d/override.conf >/dev/null <<EOF
[Service]
User=$MEDIA_USER
Group=$MEDIA_GROUP
Type=simple
ExecStart=
ExecStart=/usr/bin/transmission-daemon -f --log-error
EOF


sudo systemctl daemon-reload
sudo systemctl start transmission-daemon || true
sudo systemctl enable transmission-daemon || true
echo "Transmission installation and configuration complete."

# Check transmission-daemon status
echo "=== Checking transmission-daemon status ==="
trans_status=$(sudo systemctl status transmission-daemon | grep Active)
echo "$trans_status"
if echo "$trans_status" | grep -q -E 'inactive|dead'; then
  echo "WARNING: transmission-daemon is not running (status: $trans_status)"
fi

###############################################
# CHANNELS DVR (Docker)
###############################################
banner "=== Deploying Channels DVR ==="

docker pull fancybits/channels-dvr:tve

docker stop channels-dvr 2>/dev/null || true
docker rm channels-dvr 2>/dev/null || true

docker run -d --name=channels-dvr \
  --restart=unless-stopped \
  --network=host \
  -e TZ="America/New_York" \
  -v /opt/channels-dvr:/channels-dvr \
  -v "$MEDIA_ROOT/channels-data:/channels-data" \
  -v "$MEDIA_ROOT/tv:/tv" \
  -v "$MEDIA_ROOT/movies:/movies" \
  -v "$MEDIA_ROOT/plexserver:/mnt/cloud/plexserver" \
  fancybits/channels-dvr:tve

###############################################
# JACKETT
###############################################
echo "=== Deploying Jackett ==="

docker pull lscr.io/linuxserver/jackett:latest

docker stop jackett 2>/dev/null || true
docker rm jackett 2>/dev/null || true

docker run -d \
  --name=jackett \
  --restart=unless-stopped \
  --dns="$DNSMASQ_IP" \
  --dns=192.168.1.1 \
  --dns=8.8.8.8 \
  --dns=1.1.1.1 \
  --add-host "$HOSTNAME_LOCAL:$HOST_IP" \
  -e PUID=$(id -u "$MEDIA_USER") \
  -e PGID=$(id -g "$MEDIA_GROUP") \
  -e TZ="America/New_York" \
  -p 9117:9117 \
  -v "$MEDIA_ROOT/jackett-config:/config" \
  -v "$MEDIA_ROOT/downloads:/downloads" \
  -v "$MEDIA_ROOT/plexserver:/mnt/cloud/plexserver" \
  lscr.io/linuxserver/jackett:latest
  
###############################################
# SONARR
###############################################
echo "=== Deploying Sonarr ==="

docker pull lscr.io/linuxserver/sonarr:latest

docker stop sonarr 2>/dev/null || true
docker rm sonarr 2>/dev/null || true

docker run -d \
  --name=sonarr \
  --restart=unless-stopped \
  --dns="$DNSMASQ_IP" \
  --dns=192.168.1.1 \
  --dns=8.8.8.8 \
  --dns=1.1.1.1 \
  --add-host "$HOSTNAME_LOCAL:$HOST_IP" \
  -e PUID=$(id -u "$MEDIA_USER") \
  -e PGID=$(id -g "$MEDIA_GROUP") \
  -e TZ="America/New_York" \
  -p 8989:8989 \
  -v "$MEDIA_ROOT/sonarr-config:/config" \
  -v "$MEDIA_ROOT/tv:/tv" \
  -v "$MEDIA_ROOT/downloads:/downloads" \
  -v "$MEDIA_ROOT/plexserver:/mnt/cloud/plexserver" \
  lscr.io/linuxserver/sonarr:latest

###############################################
# RADARR
###############################################
banner "=== Deploying Radarr ==="

docker pull lscr.io/linuxserver/radarr:latest

docker stop radarr 2>/dev/null || true
docker rm radarr 2>/dev/null || true

docker run -d \
  --name=radarr \
  --restart=unless-stopped \
  --dns="$DNSMASQ_IP" \
  --dns=192.168.1.1 \
  --dns=8.8.8.8 \
  --dns=1.1.1.1 \
  --add-host "$HOSTNAME_LOCAL:$HOST_IP" \
  -e PUID=$(id -u "$MEDIA_USER") \
  -e PGID=$(id -g "$MEDIA_GROUP") \
  -e TZ="America/New_York" \
  -p 7878:7878 \
  -v "$MEDIA_ROOT/radarr-config:/config" \
  -v "$MEDIA_ROOT/movies:/movies" \
  -v "$MEDIA_ROOT/downloads:/downloads" \
  -v "$MEDIA_ROOT/plexserver:/mnt/cloud/plexserver" \
  lscr.io/linuxserver/radarr:latest

###############################################
# DONE
###############################################
echo

banner "=== Installation Complete ==="

echo "Channels DVR: http://$DVRHOSTNAME_LOCAL:8089"
echo "Jackett:      http://$DVRHOSTNAME_LOCAL:9117"
echo "Sonarr:       http://$DVRHOSTNAME_LOCAL:8989"
echo "Radarr:       http://$DVRHOSTNAME_LOCAL:7878"
echo "Transmission: http://$DVRHOSTNAME_LOCAL:9091"

# Docker container status check
echo
echo "=== Docker containers running ==="
docker ps

###############################################
# HOSTNAME.local (portable)
###############################################
if [[ $# -ge 1 ]]; then
  HOSTNAME_LOCAL="$1"
else
  HOSTNAME_LOCAL="$(hostname -s).local"
fi

echo "=== Using Hostname: $HOSTNAME_LOCAL ==="

JACKETT_URL="http://$HOSTNAME_LOCAL:9117"
SONARR_URL="http://$HOSTNAME_LOCAL:8989"
RADARR_URL="http://$HOSTNAME_LOCAL:7878"

###############################################
# READ API KEYS
###############################################
echo "=== Reading API keys ==="

JACKETT_API=$(docker exec jackett cat /config/Jackett/ServerConfig.json | jq -r '.APIKey')
SONARR_API=$(docker exec sonarr cat /config/config.xml | grep -oPm1 "(?<=<ApiKey>)[^<]+")
RADARR_API=$(docker exec radarr cat /config/config.xml | grep -oPm1 "(?<=<ApiKey>)[^<]+")

echo "Jackett API: $JACKETT_API"
echo "Sonarr API:  $SONARR_API"
echo "Radarr API:  $RADARR_API"
echo

###############################################
# TRANSMISSION CREDENTIALS
###############################################
TRANSMISSION_USER="transmission"
TRANSMISSION_PASS="transmission"

###############################################
# DELETE EXISTING INDEXER (Sonarr/Radarr)
###############################################
delete_existing_indexer() {
  local APP_NAME=$1
  local APP_URL=$2
  local APP_API=$3
  local NAME=$4

  echo "→ Checking for existing indexer $NAME in $APP_NAME"
  EXISTING=$(curl -s "$APP_URL/api/v3/indexer" -H "X-Api-Key: $APP_API")
    # Suppress JSON output

  ID=$(echo "$EXISTING" | jq -r ".[] | select(.name==\"$NAME\") | .id")

  if [[ -n "$ID" && "$ID" != "null" ]]; then
    echo "→ Removing existing $NAME from $APP_NAME (id=$ID)"
    DELETE_RESPONSE=$(curl -s -X DELETE "$APP_URL/api/v3/indexer/$ID" \
      -H "X-Api-Key: $APP_API")
    echo "Delete response:"
    echo "$DELETE_RESPONSE"
  fi
}

###############################################
# ADD INDEXER TO SONARR/RADARR
###############################################
push_indexer() {
  local APP_NAME=$1
  local APP_URL=$2
  local APP_API=$3
  local NAME=$4
  local TORZNAB=$5

  echo "→ Linking $NAME to $APP_NAME"

  # Set categories for Sonarr (TV) and Radarr (Movies)
  APP_NAME_CLEAN=$(echo "$APP_NAME" | awk '{print tolower($0)}' | xargs)
  # Use custom categories for thepiratebay in Radarr, else defaults
  if [[ "$APP_NAME_CLEAN" == "radarr" ]]; then
    if [[ "$NAME" == "thepiratebay" ]]; then
      # Custom categories for thepiratebay in Radarr
      CATEGORIES="[2000,2020,2040,2045,100201,100208,100211]"
    else
      # Jackett default movie categories: 2000 (Movies), 2010 (HD), 2020 (4K), plus 5030 (HD - TV shows)
      CATEGORIES="[2000,2010,2020,5030]"
    fi
  else
    # Jackett default TV categories: 5000 (TV), 5030 (HD), 5040 (Anime)
    CATEGORIES="[5000,5030,5040]"
  fi

  RESPONSE=$(curl -s -X POST "$APP_URL/api/v3/indexer" \
    -H "X-Api-Key: $APP_API" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"$NAME\",
      \"enable\": true,
      \"protocol\": \"torrent\", 
      \"implementation\": \"Torznab\", 
      \"configContract\": \"TorznabSettings\", 
      \"enableRss\": true, 
      \"enableAutomaticSearch\": true, 
      \"enableInteractiveSearch\": true, 
      \"supportsRss\": true, 
      \"supportsSearch\": true, 
      \"supportsInteractiveSearch\": true, 
      \"priority\": 25, 
      \"tags\": [], 
      \"fields\": [
        { \"name\": \"baseUrl\", \"value\": \"$TORZNAB\" },
        { \"name\": \"apiKey\", \"value\": \"$JACKETT_API\" },
        { \"name\": \"categories\", \"value\": $CATEGORIES }
      ]
    }")

  APP_NAME_CLEAN_PRINT=$(echo "$APP_NAME" | awk '{print tolower($0)}' | xargs)
  if [[ "$APP_NAME_CLEAN_PRINT" == "radarr" ]]; then
    # Only print error if present, suppress JSON output
    if echo "$RESPONSE" | grep -q 'error' || echo "$RESPONSE" | grep -q 'Exception'; then
      echo "  [ERROR] Failed to add $NAME to Radarr. See response above."
      echo "$RESPONSE"
    fi
  fi
}

###############################################
# DELETE EXISTING TRANSMISSION CLIENT
###############################################
delete_existing_download_client() {
  local APP_NAME=$1
  local APP_URL=$2
  local APP_API=$3

  echo "→ Checking for existing Transmission client in $APP_NAME"

  local json_file="/tmp/sarr-downloadclients-${APP_NAME,,}.json"

  # Cleanup previous file (optional but cleaner)
  rm -f "$json_file"

  if ! curl -s -S --fail \
    -H "X-Api-Key: $APP_API" \
    -o "$json_file" \
    "$APP_URL/api/v3/downloadclient"; then

    local http_code=$?
    echo "  [ERROR] Failed to get download clients from $APP_NAME"
    echo "  curl exit code: $http_code"
    [[ -f "$json_file" ]] && echo "  Response body:" && cat "$json_file"
    return 1
  fi

  local EXISTING
  EXISTING=$(cat "$json_file")

  if [[ -z "$EXISTING" ]]; then
    echo "  [WARN] Empty response from $APP_NAME API"
    return 1
  fi

  if ! jq empty <<< "$EXISTING" >/dev/null 2>&1; then
    echo "  [ERROR] Response is not valid JSON:"
    echo "  $EXISTING"
    return 1
  fi

  local ID
  ID=$(jq -r '.[] | select(.implementation=="Transmission") | .id' <<< "$EXISTING")

  if [[ -n "$ID" && "$ID" != "null" ]]; then
    echo "  → Removing existing Transmission client (id=$ID)"
    local DELETE_RESPONSE
    DELETE_RESPONSE=$(curl -s -S -X DELETE \
      -H "X-Api-Key: $APP_API" \
      "$APP_URL/api/v3/downloadclient/$ID")

    echo "  Delete response: $DELETE_RESPONSE"
  else
    echo "  [INFO] No Transmission download client found"
  fi

  # Optional: cleanup
  # rm -f "$json_file"
}

###############################################
# ADD TRANSMISSION CLIENT
###############################################
add_transmission_client() {
  local APP_NAME=$1
  local APP_URL=$2
  local APP_API=$3

  CATEGORY_VALUE="tv-sonarr"
  # Normalize APP_NAME for comparison (case-insensitive, trim)
  APP_NAME_CLEAN=$(echo "$APP_NAME" | awk '{print tolower($0)}' | xargs)
  if [[ "$APP_NAME_CLEAN" == "radarr" ]]; then
    CATEGORY_VALUE="movies-radarr"
  fi
  RESPONSE=$(curl -s -X POST "$APP_URL/api/v3/downloadclient" \
    -H "X-Api-Key: $APP_API" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"Transmission\",
      \"enable\": true,
      \"protocol\": \"torrent\",
      \"priority\": 1,
      \"implementation\": \"Transmission\",
      \"configContract\": \"TransmissionSettings\",
      \"tags\": [],
      \"fields\": [
        { \"name\": \"host\", \"value\": \"$HOSTNAME_LOCAL\" },
        { \"name\": \"port\", \"value\": 9091 },
        { \"name\": \"useSsl\", \"value\": false },
        { \"name\": \"urlBase\", \"value\": \"/transmission\" },
        { \"name\": \"username\", \"value\": \"$TRANSMISSION_USER\" },
        { \"name\": \"password\", \"value\": \"$TRANSMISSION_PASS\" },
        { \"name\": \"category\", \"value\": \"$CATEGORY_VALUE\" },
        { \"name\": \"recentPriority\", \"value\": 1 },
        { \"name\": \"olderPriority\", \"value\": 1 },
        { \"name\": \"removeCompleted\", \"value\": true }
      ]
    }")

  # Check for error in response
  if [[ "$RESPONSE" == *'"error"'* || "$RESPONSE" == *'"errors"'* ]]; then
    echo "ERROR: Failed to add Transmission client to $APP_NAME. Response:"
    echo "$RESPONSE"
    return 1
  fi

  # Check if the client was actually added by querying the list
  CLIENT_ID=$(curl -s "$APP_URL/api/v3/downloadclient" -H "X-Api-Key: $APP_API" | jq -r '.[] | select(.implementation=="Transmission") | .id')
  if [[ -n "$CLIENT_ID" && "$CLIENT_ID" != "null" ]]; then
    echo "→ Successfully added Transmission client to $APP_NAME (id=$CLIENT_ID)"
  else
    echo "ERROR: Transmission client was not added to $APP_NAME. Response:"
    echo "$RESPONSE"
    return 1
  fi
}

###############################################
# ADD REMOTE PATH MAPPINGS
###############################################
add_remote_path_mapping() {
  local APP_NAME=$1
  local APP_URL=$2
  local APP_API=$3
  local HOST_PATH=$4
  local LOCAL_PATH=$5

  echo "→ Fetching Transmission client ID for $APP_NAME"

  for i in {1..10}; do
    CLIENT_ID=$(curl -s "$APP_URL/api/v3/downloadclient" -H "X-Api-Key: $APP_API" \
      | jq -r '.[] | select(.implementation=="Transmission") | .id')

    [[ -n "$CLIENT_ID" && "$CLIENT_ID" != "null" ]] && break

    echo "  Waiting for Transmission client to register..."
    sleep 1
  done

    if [[ -z "$CLIENT_ID" || "$CLIENT_ID" == "null" ]]; then
      echo "ERROR: Could not determine Transmission client ID for $APP_NAME. Aborting remote path mapping."
      return 1
    fi
    echo "  Transmission client ID = $CLIENT_ID"
    echo "  Host for mapping: $HOSTNAME_LOCAL (must match Sonarr/Radarr download client host exactly!)"

  echo "→ Checking existing Remote Path Mappings"
  EXISTING=$(curl -s "$APP_URL/api/v3/remotepathmapping" -H "X-Api-Key: $APP_API")

  # Remove all mappings for this host+remotePath+localPath (with or without trailing slash)
  HOST_PATH_WITH_SLASH="$HOST_PATH"
  LOCAL_PATH_WITH_SLASH="$LOCAL_PATH"
  [[ "$HOST_PATH_WITH_SLASH" != */ ]] && HOST_PATH_WITH_SLASH="$HOST_PATH_WITH_SLASH/"
  [[ "$LOCAL_PATH_WITH_SLASH" != */ ]] && LOCAL_PATH_WITH_SLASH="$LOCAL_PATH_WITH_SLASH/"

  # Remove all matching mappings (with or without trailing slash)
  MAP_IDS=$(echo "$EXISTING" | jq -r ".[] | select(.host==\"$HOSTNAME_LOCAL\" and (.remotePath==\"$HOST_PATH\" or .remotePath==\"$HOST_PATH_WITH_SLASH\") and (.localPath==\"$LOCAL_PATH\" or .localPath==\"$LOCAL_PATH_WITH_SLASH\")) | .id")
  for MAP_ID in $MAP_IDS; do
    if [[ -n "$MAP_ID" && "$MAP_ID" != "null" ]]; then
      echo "→ Removing existing mapping (id=$MAP_ID)"
      DELETE_RESPONSE=$(curl -s -X DELETE "$APP_URL/api/v3/remotepathmapping/$MAP_ID" \
        -H "X-Api-Key: $APP_API")
      # Suppress JSON output
    fi
  done

  echo "→ Adding Remote Path Mapping to $APP_NAME"
  POST_PAYLOAD="{\"host\":\"$HOSTNAME_LOCAL\",\"remotePath\":\"$HOST_PATH_WITH_SLASH\",\"localPath\":\"$LOCAL_PATH_WITH_SLASH\",\"downloadClientId\":$CLIENT_ID}"
  echo "POST payload: $POST_PAYLOAD"
  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$APP_URL/api/v3/remotepathmapping" \
    -H "X-Api-Key: $APP_API" \
    -H "Content-Type: application/json" \
    -d "$POST_PAYLOAD")
  HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
  BODY=$(echo "$RESPONSE" | head -n -1)
  echo "Remote Path Mapping POST response:"
  # Suppress JSON output
  if [[ "$HTTP_CODE" != "201" ]]; then
    echo "ERROR: Failed to add remote path mapping to $APP_NAME (HTTP $HTTP_CODE)"
    # Suppress JSON output
  fi
}

###############################################
# ADD ROOT FOLDER TO SONARR/RADARR
###############################################
add_root_folder() {
  local APP_NAME=$1
  local APP_URL=$2
  local APP_API=$3
  local LOCAL_PATH=$4

  # Check if folder exists
  EXISTING=$(curl -s "$APP_URL/api/v3/rootfolder" -H "X-Api-Key: $APP_API")
    FOLDER_ID=$(echo "$EXISTING" | jq -r ".[] | select(.path==\"$LOCAL_PATH\") | .id")
  if [[ -n "$FOLDER_ID" && "$FOLDER_ID" != "null" ]]; then
    return
  fi
  # Add folder
    RESPONSE=$(curl -s -X POST "$APP_URL/api/v3/rootfolder" \
      -H "X-Api-Key: $APP_API" \
      -H "Content-Type: application/json" \
      -d "{\"path\":\"$LOCAL_PATH\"}")
  if [[ "$RESPONSE" == *'"error"'* || "$RESPONSE" == *'"errors"'* ]]; then
      echo "Error adding root folder $LOCAL_PATH to $APP_NAME:"
      # Suppress JSON output
  fi
}

###############################################
# WAIT FOR SONARR AND RADARR TO START
###############################################
banner "Waiting 15 seconds for Sonarr and Radarr to fully start..."

sleep 15

###############################################
# TRANSMISSION → SONARR/RADARR
###############################################
banner "=== Configuring Transmission client and remote path mapping and root folder in Sonarr ==="

delete_existing_download_client "Sonarr" "$SONARR_URL" "$SONARR_API"
add_transmission_client "Sonarr" "$SONARR_URL" "$SONARR_API"
add_root_folder "Sonarr" "$SONARR_URL" "$SONARR_API" "/tv"
add_remote_path_mapping "Sonarr" "$SONARR_URL" "$SONARR_API" "/mnt/cloud/downloads/tv-sonarr" "/downloads/tv-sonarr"

banner "=== Configuring Transmission client and remote path mapping and root folder in Radarr ==="

delete_existing_download_client "Radarr" "$RADARR_URL" "$RADARR_API"
add_transmission_client "Radarr" "$RADARR_URL" "$RADARR_API"
add_root_folder "Radarr" "$RADARR_URL" "$RADARR_API" "/movies"
add_remote_path_mapping "Radarr" "$RADARR_URL" "$RADARR_API" "/mnt/cloud/downloads/radarr" "/downloads/radarr"

echo

###############################################
# DETECT CONFIGURED JACKETT INDEXERS
###############################################
echo "=== Detecting configured Jackett indexers ==="

INDEXER_FILES=$(docker exec jackett ls /config/Jackett/Indexers 2>/dev/null \
  | grep -E '\.json$' \
  | grep -vE '\.bak$|\.old$|\.disabled$' \
  || true)

if [[ -z "$INDEXER_FILES" ]]; then
  banner "No active indexers found in Jackett.  Setup and enable indexers in Jackett first.  Then re-run this script to link them to Sonarr and Radarr."
  
else

  echo "Active indexers:"
  echo "$INDEXER_FILES"
  echo

  ###############################################
  # PROCESS EACH INDEXER
  ###############################################
  echo "=== Linking Jackett indexers to Sonarr and Radarr ==="

  for FILE in $INDEXER_FILES; do
    NAME="${FILE%.json}"
    TORZNAB_URL="$JACKETT_URL/api/v2.0/indexers/$NAME/results/torznab/"

    echo "Indexer: $NAME"
    echo "Torznab URL: $TORZNAB_URL"

    delete_existing_indexer "Sonarr" "$SONARR_URL" "$SONARR_API" "$NAME"
    push_indexer "Sonarr" "$SONARR_URL" "$SONARR_API" "$NAME" "$TORZNAB_URL"

    delete_existing_indexer "Radarr" "$RADARR_URL" "$RADARR_API" "$NAME"
    push_indexer "Radarr" "$RADARR_URL" "$RADARR_API" "$NAME" "$TORZNAB_URL"

    echo
  done
fi

echo "=== DONE ==="
echo "Transmission, Remote Path Mappings, and all Jackett indexers have been refreshed in Sonarr and Radarr."

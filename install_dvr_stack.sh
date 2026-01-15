#!/bin/bash
set -euo pipefail

MEDIA_USER="media"
MEDIA_GROUP="media"
MEDIA_ROOT="/mnt/cloud"
NAS_IP="${NAS_IP:-192.168.1.30}"
username="${YOURUSER:-media}"
password="${YOURPASS:-changeme}"
domain="WORKGROUP"
###############################################
echo "=== Validating environment ==="

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

###############################################
# DIRECTORY STRUCTURE
###############################################
echo "=== Ensuring directory structure under $MEDIA_ROOT ==="

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
echo "=== Configuring CIFS mountpoints and fstab entries ==="

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
echo "=== Installing base dependencies ==="
sudo apt update
sudo apt install -y curl wget jq ca-certificates gnupg software-properties-common cifs-utils netatalk

###############################################
# NETATALK CONFIG
###############################################
echo "=== Configuring Netatalk (AFP) ==="

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
echo "=== Enabling unprivileged user namespaces ==="
echo "kernel.unprivileged_userns_clone=1" | sudo tee /etc/sysctl.d/99-userns.conf >/dev/null
sudo sysctl --system >/dev/null || echo "WARNING: sysctl reload failed."

###############################################
# INSTALL DOCKER ENGINE
###############################################
echo "=== Installing Docker Engine ==="

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
echo "=== Installing Transmission ==="

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

# Create hard link for settings.json if not present
if [[ ! -f "$USER_CONFIG_DIR/settings.json" ]]; then
  sudo ln "$TRANSMISSION_CONFIG" "$USER_CONFIG_DIR/settings.json"
fi

if [[ -f "$TRANSMISSION_CONFIG" ]]; then
  TMP_JSON=$(sudo mktemp)

  sudo jq \
  --arg dl "$MEDIA_ROOT/downloads" \
  --arg inc "$MEDIA_ROOT/downloads/incomplete" \
  --arg watch "$MEDIA_ROOT/downloads/watch" \
    '.
     | .["download-dir"]=$dl
     | .["incomplete-dir"]=$inc
     | .["incomplete-dir-enabled"]=true
     | .["alt-speed-enabled"]=false
     | .["alt-speed-down"]=50
     | .["alt-speed-up"]=50
     | .["alt-speed-time-begin"]=540
     | .["alt-speed-time-day"]=127
     | .["alt-speed-time-enabled"]=false
     | .["alt-speed-time-end"]=1020
     | .["peer-id-ttl-hours"]=6
     | .["peer-port"]=60875
     | .["peer-port-random-on-start"]=true
     | .["peer-port-random-low"]=49152
     | .["peer-port-random-high"]=65535
     | .["port-forwarding-enabled"]=true
     | .["max-peers-global"]=200
     | .["peer-limit-global"]=200
     | .["peer-limit-per-torrent"]=50
     | .["upload-slots-per-torrent"]=0
     | .["upload-limit"]=0
     | .["upload-limit-enabled"]=true
     | .["speed-limit-up"]=0
     | .["speed-limit-up-enabled"]=true
     | .["speed-limit-down"]=100
     | .["speed-limit-down-enabled"]=false
     | .["download-limit"]=100
     | .["download-limit-enabled"]=0
     | .["download-queue-enabled"]=true
     | .["download-queue-size"]=15
     | .["seed-queue-enabled"]=false
     | .["seed-queue-size"]=0
     | .["idle-seeding-limit"]=0
     | .["idle-seeding-limit-enabled"]=true
     | .["ratio-limit"]=0
     | .["ratio-limit-enabled"]=true
     | .["rename-partial-files"]=true
     | .["lpd-enabled"]=false
     | .["dht-enabled"]=true
     | .["pex-enabled"]=true
     | .["utp-enabled"]=true
     | .["tcp-enabled"]=true
     | .["preallocation"]=1
     | .["prefetch-enabled"]=true
     | .["queue-stalled-enabled"]=true
     | .["queue-stalled-minutes"]=30
     | .["scrape-paused-torrents-enabled"]=true
     | .["start-added-torrents"]=true
     | .["torrent-added-verify-mode"]="fast"
     | .["trash-original-torrent-files"]=false
     | .["umask"]="002"
     | .["rpc-enabled"]=true
     | .["rpc-bind-address"]="0.0.0.0"
     | .["rpc-authentication-required"]=true
     | .["rpc-whitelist-enabled"]=false
     | .["rpc-host-whitelist-enabled"]=false
     | .["rpc-host-whitelist"]="127.0.0.1,192.168.1.*"
     | .["rpc-whitelist"]="127.0.0.1,192.168.1.*"
     | .["rpc-port"]=9091
     | .["rpc-socket-mode"]="0750"
     | .["rpc-url"]="/transmission/"
     | .["rpc-username"]="transmission"
     | .["watch-dir"]=$watch
     | .["watch-dir-enabled"]=true' \
    "$TRANSMISSION_CONFIG" | sudo tee "$TMP_JSON" >/dev/null

  sudo mv "$TMP_JSON" "$TRANSMISSION_CONFIG"
  sudo chown "$MEDIA_USER:$MEDIA_GROUP" "$TRANSMISSION_CONFIG"
fi

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

###############################################
# CHANNELS DVR (Docker)
###############################################
echo "=== Deploying Channels DVR ==="

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
# SONARR
###############################################
echo "=== Deploying Sonarr ==="

docker pull lscr.io/linuxserver/sonarr:latest

docker stop sonarr 2>/dev/null || true
docker rm sonarr 2>/dev/null || true

docker run -d \
  --name=sonarr \
  --restart=unless-stopped \
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
echo "=== Deploying Radarr ==="

docker pull lscr.io/linuxserver/radarr:latest

docker stop radarr 2>/dev/null || true
docker rm radarr 2>/dev/null || true

docker run -d \
  --name=radarr \
  --restart=unless-stopped \
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
echo "=== Installation Complete ==="
HOSTNAME_LOCAL="dvr-$(hostname).local"
echo "Channels DVR: http://$HOSTNAME_LOCAL:8089"
echo "Jackett:      http://$HOSTNAME_LOCAL:9117"
echo "Sonarr:       http://$HOSTNAME_LOCAL:8989"
echo "Radarr:       http://$HOSTNAME_LOCAL:7878"
echo "Transmission: http://$HOSTNAME_LOCAL:9091"
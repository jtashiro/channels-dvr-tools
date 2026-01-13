#!/bin/bash
set -euo pipefail

MEDIA_USER="media"
MEDIA_GROUP="media"
MEDIA_ROOT="/mnt/cloud"

echo "=== Validating environment ==="

if [[ "$(id -un)" != "$MEDIA_USER" ]]; then
  echo "ERROR: Must run as user '$MEDIA_USER'. Current user: '$(id -un)'."
  exit 1
fi

if [[ ! -d "$MEDIA_ROOT" ]]; then
  echo "ERROR: $MEDIA_ROOT does not exist or is not mounted."
  exit 1
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
  "$MEDIA_ROOT/plexserver" \
  "$MEDIA_ROOT/jackett-config" \
  "$MEDIA_ROOT/sonarr-config" \
  "$MEDIA_ROOT/radarr-config"

sudo chown -R "$MEDIA_USER:$MEDIA_GROUP" "$MEDIA_ROOT"

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
# CIFS MOUNTS + SMB CREDENTIALS + FSTAB
###############################################
echo "=== Configuring CIFS mountpoints and fstab entries ==="

sudo mkdir -p /mnt/cloud-nas /mnt/cloud2-nas
sudo chown "$MEDIA_USER:$MEDIA_GROUP" /mnt/cloud-nas /mnt/cloud2-nas

if [[ ! -f /etc/smb-cred ]]; then
  echo "Creating /etc/smb-cred (edit manually)..."
  sudo tee /etc/smb-cred >/dev/null <<EOF
username=YOURUSER
password=YOURPASS
domain=YOURDOMAIN
EOF
  sudo chmod 600 /etc/smb-cred
fi

if ! grep -q "cloud-nas" /etc/fstab; then
  sudo tee -a /etc/fstab >/dev/null <<EOF

# NAS shares
//192.168.1.30/cloud   /mnt/cloud-nas   cifs   credentials=/etc/smb-cred,vers=3.1.1,uid=1001,gid=1001,nofail,x-systemd.automount,x-systemd.idle-timeout=30,_netdev,noserverino   0   0
//192.168.1.30/cloud2  /mnt/cloud2-nas  cifs   credentials=/etc/smb-cred,vers=3.1.1,uid=1001,gid=1001,nofail,x-systemd.automount,x-systemd.idle-timeout=30,_netdev,noserverino   0   0
EOF
fi

sudo systemctl daemon-reload
sudo mount -a || echo "WARNING: CIFS mounts may not be available until network is up."

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
sudo mkdir -p "$USER_CONFIG_DIR"
if [[ ! -f "$USER_CONFIG_DIR/settings.json" ]]; then
  sudo ln "$TRANSMISSION_CONFIG" "$USER_CONFIG_DIR/settings.json"
fi

if [[ -f "$TRANSMISSION_CONFIG" ]]; then
  TMP_JSON=$(sudo mktemp)

  sudo jq \
  --arg dl "$MEDIA_ROOT/downloads" \
  --arg inc "$MEDIA_ROOT/downloads/incomplete" \
  --arg watch "$MEDIA_ROOT/downloads/watch" \
    '.["download-dir"]=$dl
     | .["incomplete-dir"]=$inc
     | .["incomplete-dir-enabled"]=true
     | .["rpc-enabled"]=true
     | .["rpc-bind-address"]="0.0.0.0"
     | .["rpc-authentication-required"]=true
     | .["rpc-whitelist-enabled"]=false
     | .["rpc-host-whitelist-enabled"]=false
     | .["watch-dir"]=$watch
     | .["watch-dir-enabled"]=true' \
    "$TRANSMISSION_CONFIG" | sudo tee "$TMP_JSON" >/dev/null

  sudo mv "$TMP_JSON" "$TRANSMISSION_CONFIG"
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
sudo systemctl enable transmission-daemon
sudo systemctl restart transmission-daemon

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
# JACKETT
###############################################
echo "=== Deploying Jackett ==="

docker pull lscr.io/linuxserver/jackett:latest

docker stop jackett 2>/dev/null || true
docker rm jackett 2>/dev/null || true

docker run -d \
  --name=jackett \
  --restart=unless-stopped \
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
echo "Channels DVR: http://<server-ip>:8089"
echo "Jackett:      http://<server-ip>:9117"
echo "Sonarr:       http://<server-ip>:8989"
echo "Radarr:       http://<server-ip>:7878"
echo "Transmission: http://<server-ip>:9091"
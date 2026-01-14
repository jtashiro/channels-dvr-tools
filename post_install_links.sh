#!/bin/bash
set -euo pipefail
export PATH=$PATH:/usr/bin

###############################################
# HOSTNAME.local (portable)
###############################################
if [[ $# -ge 1 ]]; then
  HOSTNAME_LOCAL="$1"
else
  HOSTNAME_LOCAL="$(hostname).local"
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
# DETECT CONFIGURED JACKETT INDEXERS
###############################################
echo "=== Detecting configured Jackett indexers ==="

INDEXER_FILES=$(docker exec jackett ls /config/Jackett/Indexers 2>/dev/null \
  | grep -E '\.json$' \
  | grep -vE '\.bak$|\.old$|\.disabled$' \
  || true)

if [[ -z "$INDEXER_FILES" ]]; then
  echo "No active indexers found in Jackett."
  exit 1
fi

echo "Active indexers:"
echo "$INDEXER_FILES"
echo

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
  EXISTING=$(curl -s "$APP_URL/api/v3/downloadclient" -H "X-Api-Key: $APP_API")
    # Suppress JSON output

  ID=$(echo "$EXISTING" | jq -r '.[] | select(.implementation=="Transmission") | .id')

  if [[ -n "$ID" && "$ID" != "null" ]]; then
    echo "→ Removing existing Transmission client from $APP_NAME (id=$ID)"
    DELETE_RESPONSE=$(curl -s -X DELETE "$APP_URL/api/v3/downloadclient/$ID" \
      -H "X-Api-Key: $APP_API")
    echo "Delete response:"
    echo "$DELETE_RESPONSE"
  fi
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
# TRANSMISSION → SONARR/RADARR
###############################################
echo "=== Configuring Transmission client in Sonarr and Radarr ==="

delete_existing_download_client "Sonarr" "$SONARR_URL" "$SONARR_API"
add_transmission_client "Sonarr" "$SONARR_URL" "$SONARR_API"

add_root_folder "Sonarr" "$SONARR_URL" "$SONARR_API" "/tv"

delete_existing_download_client "Radarr" "$RADARR_URL" "$RADARR_API"
add_transmission_client "Radarr" "$RADARR_URL" "$RADARR_API"

add_root_folder "Radarr" "$RADARR_URL" "$RADARR_API" "/movies"

echo

###############################################
# REMOTE PATH MAPPINGS
###############################################
echo "=== Adding Remote Path Mappings ==="

add_remote_path_mapping \
  "Sonarr" "$SONARR_URL" "$SONARR_API" \
  "/mnt/cloud/downloads/tv-sonarr" \
  "/downloads/tv-sonarr"

add_remote_path_mapping \
  "Radarr" "$RADARR_URL" "$RADARR_API" \
  "/mnt/cloud/downloads/radarr" \
  "/downloads/radarr"

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

echo "=== DONE ==="
echo "Transmission, Remote Path Mappings, and all Jackett indexers have been refreshed in Sonarr and Radarr."
MEDIA_ROOT=/mnt/cloud

echo "=== Deploying Channels DVR ==="

#docker pull fancybits/channels-dvr:tve
docker pull fancybits/channels-dvr:nvidia

docker stop channels-dvr 2>/dev/null || true
docker rm channels-dvr 2>/dev/null || true

docker run --rm -it \
  -v /opt/channels-dvr:/channels-dvr \
  fancybits/channels-dvr \
  rm -rf /channels-dvr/*


docker run -d --name=channels-dvr \
  --restart=always \
  --network=host \
  --gpus all \
  --runtime=nvidia \
  -e NVIDIA_VISIBLE_DEVICES=all \
  -e NVIDIA_DRIVER_CAPABILITIES=compute,utility,video \
  -e TZ="America/New_York" \
  -v /opt/channels-dvr:/channels-dvr \
  -v "$MEDIA_ROOT/channels-data:/channels-data" \
  -v "$MEDIA_ROOT/tv:/tv" \
  -v "$MEDIA_ROOT/movies:/movies" \
  -v "$MEDIA_ROOT/plexserver:/mnt/cloud/plexserver" \
  fancybits/channels-dvr:nvidia

docker exec -it channels-dvr ls -l /channels-dvr/latest

#docker exec -it channels-dvr /channels-dvr/latest/ffmpeg -encoders | grep nvenc

#docker exec -it channels-dvr /channels-dvr/latest/ffmpeg-dl
#!/bin/sh
# Local self-hosted LiveKit for Monastack voice. Loopback only.
#
#   backend/media/livekit-dev.sh start   # create credentials if needed, start
#   backend/media/livekit-dev.sh stop
#
# Credentials and config live in $MONASTACK_DEV_DIR (default runtime/media under the repository,
# git-ignored, mode 0700). They are random, local and not production secrets.
# Rooms are never auto-created: only the Monastack control plane can create
# them, which is what makes revocation by room deletion effective.
set -eu
IMAGE='livekit/livekit-server@sha256:89ca9ce0791e18d6e03bf6e2c49ceb27e1c754eae8bd50c989386c1a5963791a'
# v1.13.10; already present locally as livekit/livekit-server:v1.13.10
LOCAL_IMAGE='sha256:89ca9ce0791e18d6e03bf6e2c49ceb27e1c754eae8bd50c989386c1a5963791a'
NAME="${MONASTACK_MEDIA_NAME:-monastack-livekit-dev}"
BIND_HOST="${MONASTACK_MEDIA_BIND_HOST:-127.0.0.1}"
NODE_IP="${MONASTACK_MEDIA_NODE_IP:-127.0.0.1}"
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNTIME_DIR="${MONASTACK_RUNTIME_DIR:-$PROJECT_ROOT/runtime}"
DIR="${MONASTACK_DEV_DIR:-$RUNTIME_DIR/media}"
SIGNAL="${MONASTACK_MEDIA_SIGNAL_PORT:-7880}"
TCP="${MONASTACK_MEDIA_TCP_PORT:-7881}"
UDP="${MONASTACK_MEDIA_UDP_PORT:-7882}"

case "${1:-}" in
  start)
    umask 077
    mkdir -p "$DIR"
    DIR="$(cd "$DIR" && pwd)"
    if [ ! -f "$DIR/media.key" ]; then
      printf 'dev%s %s\n' "$(openssl rand -hex 6)" "$(openssl rand -hex 32)" > "$DIR/media.key"
    fi
    read -r KEY SECRET < "$DIR/media.key"
    cat > "$DIR/livekit.yaml" <<YAML
port: $SIGNAL
bind_addresses: ["0.0.0.0"]
rtc:
  tcp_port: $TCP
  udp_port: $UDP
  use_external_ip: false
room:
  auto_create: false
keys:
  $KEY: $SECRET
YAML
    if docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1; then image="$LOCAL_IMAGE"; else image="$IMAGE"; fi
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --rm --name "$NAME" \
      -p "$BIND_HOST:$SIGNAL:$SIGNAL" -p "$BIND_HOST:$TCP:$TCP" -p "$BIND_HOST:$UDP:$UDP/udp" \
      --mount "type=bind,source=$DIR/livekit.yaml,target=/livekit.yaml,readonly" \
      "$image" --config /livekit.yaml --node-ip "$NODE_IP" >/dev/null
    echo "LiveKit listening on ws://127.0.0.1:$SIGNAL"
    echo "Start the node with:"
    echo "  MONASTACK_MEDIA_URL=ws://127.0.0.1:$SIGNAL MONASTACK_MEDIA_KEY_FILE=$DIR/media.key"
    ;;
  stop)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    echo "LiveKit stopped"
    ;;
  *)
    echo "usage: $0 start|stop" >&2
    exit 2
    ;;
esac

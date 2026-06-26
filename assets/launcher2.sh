#!/bin/bash
set -u

BASE_HOME="/root"
INSTANCE_HOME="$BASE_HOME/napcat_instances/qq2_home"
INSTANCE_WORKDIR="$BASE_HOME/napcat_instances/qq2_napcat"
INSTANCE_DISPLAY="${NAPCAT_SECOND_DISPLAY:-22}"

mkdir -p "$INSTANCE_HOME" "$INSTANCE_WORKDIR/config" "$INSTANCE_WORKDIR/logs" "$INSTANCE_WORKDIR/cache"

if [ -d "$BASE_HOME/napcat/config" ]; then
  cp -n "$BASE_HOME/napcat/config/"*.json "$INSTANCE_WORKDIR/config/" 2>/dev/null || true
fi

if [ -f "$INSTANCE_WORKDIR/config/onebot11.json" ]; then
  sed -i -E "s#\"url\"[[:space:]]*:[[:space:]]*\"ws://localhost:[0-9]+/ws\"#\"url\": \"ws://localhost:${ASTRBOT_ONEBOT_WS_PORT:-6199}/ws\"#g" "$INSTANCE_WORKDIR/config/onebot11.json"
fi

if [ -f "$INSTANCE_WORKDIR/config/webui.json" ]; then
  sed -i -E "s#\"(port|webuiPort|webUiPort)\"[[:space:]]*:[[:space:]]*[0-9]+#\"\\1\": ${NAPCAT_SECOND_WEBUI_PORT:-6102}#g" "$INSTANCE_WORKDIR/config/webui.json"
fi

echo "[launcher2] DISPLAY=:$INSTANCE_DISPLAY"
echo "[launcher2] NAPCAT_WORKDIR=$INSTANCE_WORKDIR"
echo "[launcher2] HOME=$INSTANCE_HOME"

if [ -f "$INSTANCE_WORKDIR/xvfb.pid" ]; then
  kill "$(cat "$INSTANCE_WORKDIR/xvfb.pid")" 2>/dev/null || true
fi
pkill -f "Xvfb :$INSTANCE_DISPLAY" 2>/dev/null || true
rm -f "/tmp/.X${INSTANCE_DISPLAY}-lock" "/tmp/.X11-unix/X${INSTANCE_DISPLAY}" 2>/dev/null || true
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix 2>/dev/null || true

Xvfb ":$INSTANCE_DISPLAY" -screen 0 800x600x16 +extension GLX +render > "$INSTANCE_WORKDIR/xvfb.log" 2>&1 &
echo "$!" > "$INSTANCE_WORKDIR/xvfb.pid"
for i in $(seq 1 50); do
  if [ -S "/tmp/.X11-unix/X${INSTANCE_DISPLAY}" ]; then
    break
  fi
  if ! kill -0 "$(cat "$INSTANCE_WORKDIR/xvfb.pid")" 2>/dev/null; then
    echo "[launcher2] Xvfb 启动失败"
    cat "$INSTANCE_WORKDIR/xvfb.log" 2>/dev/null || true
    exit 1
  fi
  sleep 0.1
done
if [ ! -S "/tmp/.X11-unix/X${INSTANCE_DISPLAY}" ]; then
  echo "[launcher2] Xvfb 未就绪，无法启动 QQ"
  cat "$INSTANCE_WORKDIR/xvfb.log" 2>/dev/null || true
  exit 1
fi
export DISPLAY=":$INSTANCE_DISPLAY"
export NAPCAT_WORKDIR="$INSTANCE_WORKDIR"
export HOME="$INSTANCE_HOME"
export XDG_CONFIG_HOME="$INSTANCE_HOME/.config"
export XDG_CACHE_HOME="$INSTANCE_HOME/.cache"
export XDG_DATA_HOME="$INSTANCE_HOME/.local/share"

mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"

cd "$BASE_HOME"
trap "" SIGPIPE
LD_PRELOAD=./libnapcat_launcher.so qq --no-sandbox

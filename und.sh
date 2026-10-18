#!/bin/sh
# understudy launcher/control for macOS and Linux
DIR="$(cd "$(dirname "$0")" && pwd)"
PIDFILE="$DIR/.proxy.pid"
LOGFILE="$DIR/proxy.log"

alive() {
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

wait_health() {
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if curl -sf -m 2 "http://127.0.0.1:${UNDERSTUDY_PORT:-8793}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

start_proxy() {
  if alive; then
    echo "understudy: already running (pid $(cat "$PIDFILE"))"
    return 0
  fi
  if command -v curl >/dev/null 2>&1 && curl -sf -m 1 "http://127.0.0.1:${UNDERSTUDY_PORT:-8793}/healthz" >/dev/null 2>&1; then
    echo "understudy: proxy already listening on port (started elsewhere)"
    return 0
  fi
  nohup node "$DIR/proxy.mjs" >>"$LOGFILE" 2>&1 &
  echo $! >"$PIDFILE"
  if wait_health; then
    echo "understudy: started (pid $(cat "$PIDFILE"), log $LOGFILE)"
  else
    echo "understudy: failed to become healthy; check $LOGFILE"
    return 1
  fi
}

stop_proxy() {
  if curl -sf -m 2 -X POST "http://127.0.0.1:${UNDERSTUDY_PORT:-8793}/shutdown" >/dev/null 2>&1; then
    echo "understudy: stopped via /shutdown"
  elif alive; then
    kill "$(cat "$PIDFILE")" 2>/dev/null && echo "understudy: killed pid $(cat "$PIDFILE")"
  else
    echo "understudy: not running"
  fi
  rm -f "$PIDFILE"
}

status_proxy() {
  if curl -sf -m 2 "http://127.0.0.1:${UNDERSTUDY_PORT:-8793}/healthz" 2>/dev/null; then
    echo ""
  else
    echo "understudy: proxy DOWN on port ${UNDERSTUDY_PORT:-8793}" >&2
    return 1
  fi
}

case "${1:-start}" in
  start) start_proxy ;;
  stop) stop_proxy ;;
  restart)
    stop_proxy
    sleep 0.5
    start_proxy
    ;;
  status) status_proxy ;;
  launch)
    start_proxy || exit 1
    export ANTHROPIC_BASE_URL="http://127.0.0.1:${UNDERSTUDY_PORT:-8793}"
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    exec claude "${@:2}"
    ;;
  *)
    echo "usage: und.sh {start|stop|restart|status|launch [-- extra claude args]}"
    echo "  start    launch the proxy in the background"
    echo "  stop     shut it down (works even if started elsewhere)"
    echo "  status   print healthz json"
    echo "  launch   start proxy, then run claude pointed at it"
    exit 1
    ;;
esac

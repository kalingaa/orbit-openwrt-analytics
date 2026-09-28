#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
CONFIG=${CONFIG:-"$ROOT/config.env"}

case "$CONFIG" in
  /*) ;;
  *) CONFIG="$ROOT/$CONFIG" ;;
esac
BUILD="$ROOT/build"

usage() {
  cat <<'EOF'
Usage: ./manage.sh COMMAND

Commands:
  check           Validate configuration, tools, and SSH connectivity
  render          Render site-specific files into build/
  test            Validate rendered JSON, YAML tokens, and sensitive samples
  install         Install or upgrade router and server
  install-router  Install or upgrade OpenWrt only
  install-server  Install or upgrade the analytics server only
  status          Show service and endpoint health
  backup          Download configuration backups into backups/
  uninstall       Print safe removal instructions (data is preserved)
EOF
}

load_config() {
  [ -f "$CONFIG" ] || { echo "Missing $CONFIG; copy config.example to config.env." >&2; exit 1; }
  set -a
  # shellcheck disable=SC1090
  . "$CONFIG"
  set +a
}

render() {
  load_config
  python3 "$ROOT/scripts/render.py" "$CONFIG"
}

check() {
  load_config
  for command in python3 ssh scp; do command -v "$command" >/dev/null || { echo "Missing: $command"; exit 1; }; done
  python3 "$ROOT/scripts/render.py" "$CONFIG" >/dev/null
  ssh -p "$ROUTER_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 "$ROUTER_SSH_USER@$ROUTER_ADDRESS" 'ubus call system board' >/dev/null || \
    echo "Router key-based SSH check failed; interactive authentication may still work."
  ssh -p "$SERVER_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 "$SERVER_SSH_USER@$SERVER_ADDRESS" 'uname -s' >/dev/null || \
    echo "Server key-based SSH check failed; interactive authentication may still work."
  echo "Preflight complete."
}

test_rendered() {
  [ -d "$BUILD" ] || render
  python3 - "$BUILD" <<'PY'
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
for path in root.glob("*dashboard.json"):
    json.loads(path.read_text(encoding="utf-8"))
bad = []
for path in root.rglob("*"):
    if path.is_file():
        text = path.read_text(encoding="utf-8", errors="ignore")
        if re.search(r"__[A-Z0-9_]+__", text): bad.append(str(path))
if bad: raise SystemExit("Unsafe or unresolved rendered files:\n" + "\n".join(sorted(set(bad))))
print("Rendered configuration validation passed.")
PY
}

install_router() {
  render
  test_rendered
  remote="/tmp/openwrt-network-analytics.$$"
  ssh -p "$ROUTER_SSH_PORT" "$ROUTER_SSH_USER@$ROUTER_ADDRESS" "mkdir -p '$remote'"
  scp -P "$ROUTER_SSH_PORT" -r "$BUILD/." "$ROUTER_SSH_USER@$ROUTER_ADDRESS:$remote/"
  scp -P "$ROUTER_SSH_PORT" "$ROOT/scripts/install-router.sh" "$ROUTER_SSH_USER@$ROUTER_ADDRESS:$remote/"
  ssh -t -p "$ROUTER_SSH_PORT" "$ROUTER_SSH_USER@$ROUTER_ADDRESS" "sh '$remote/install-router.sh' '$remote' '$LAN_CIDR'"
}

install_server() {
  render
  test_rendered
  remote="/tmp/openwrt-network-analytics.$$"
  ssh -p "$SERVER_SSH_PORT" "$SERVER_SSH_USER@$SERVER_ADDRESS" "mkdir -p '$remote'"
  scp -P "$SERVER_SSH_PORT" -r "$BUILD/." "$SERVER_SSH_USER@$SERVER_ADDRESS:$remote/"
  scp -P "$SERVER_SSH_PORT" "$ROOT/scripts/install-server.sh" "$SERVER_SSH_USER@$SERVER_ADDRESS:$remote/"
  ssh -t -p "$SERVER_SSH_PORT" "$SERVER_SSH_USER@$SERVER_ADDRESS" "sudo sh '$remote/install-server.sh' '$remote'"
}

status() {
  load_config
  ssh -p "$ROUTER_SSH_PORT" "$ROUTER_SSH_USER@$ROUTER_ADDRESS" \
    '/etc/init.d/nlbwmon status; /etc/init.d/netifyd status; /etc/init.d/prometheus-node-exporter-lua status'
  ssh -p "$SERVER_SSH_PORT" "$SERVER_SSH_USER@$SERVER_ADDRESS" \
    'systemctl is-active prometheus prometheus-node-exporter grafana-server; curl -fsS http://127.0.0.1:9090/-/ready; curl -fsS http://127.0.0.1:3000/api/health'
}

backup() {
  load_config
  stamp=$(date +%Y%m%d-%H%M%S)
  target="$ROOT/backups/$stamp"
  mkdir -p "$target/router" "$target/server"
  scp -P "$ROUTER_SSH_PORT" "$ROUTER_SSH_USER@$ROUTER_ADDRESS:/etc/config/nlbwmon" "$target/router/" || true
  scp -P "$ROUTER_SSH_PORT" "$ROUTER_SSH_USER@$ROUTER_ADDRESS:/etc/config/netifyd" "$target/router/" || true
  scp -P "$ROUTER_SSH_PORT" "$ROUTER_SSH_USER@$ROUTER_ADDRESS:/etc/prometheus-device-names" "$target/router/" || true
  scp -P "$SERVER_SSH_PORT" -r "$SERVER_SSH_USER@$SERVER_ADDRESS:/etc/prometheus" "$target/server/" || true
  scp -P "$SERVER_SSH_PORT" -r "$SERVER_SSH_USER@$SERVER_ADDRESS:/etc/grafana/provisioning" "$target/server/" || true
  scp -P "$SERVER_SSH_PORT" "$SERVER_SSH_USER@$SERVER_ADDRESS:/var/lib/grafana/grafana.db" "$target/server/" || true
  echo "Backup saved to $target"
}

uninstall_info() {
  cat <<'EOF'
Uninstall is intentionally non-destructive in this release.

1. Run ./manage.sh backup.
2. On OpenWrt, disable the exporter, remove these two nftables includes, and
   reload fw4:
     /etc/nftables.d/90-openwrt-network-analytics-apps.nft
     /etc/nftables.d/91-openwrt-network-analytics-devices.nft
3. On the server, remove the openwrt scrape jobs/rules and provisioned dashboard
   files, then restart Prometheus and Grafana.

Prometheus history, Grafana's database, aliases, and packages are preserved.
EOF
}

command=${1:-help}
case "$command" in
  check) check ;;
  render) render ;;
  test) load_config; test_rendered ;;
  install) load_config; install_router; install_server ;;
  install-router) load_config; install_router ;;
  install-server) load_config; install_server ;;
  status) status ;;
  backup) backup ;;
  uninstall) uninstall_info ;;
  help|-h|--help) usage ;;
  *) usage >&2; exit 1 ;;
esac

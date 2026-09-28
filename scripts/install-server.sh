#!/bin/sh
set -eu

BUILD_DIR=${1:?usage: install-server.sh BUILD_DIR}
BACKUP_DIR="/var/backups/openwrt-network-analytics/$(date +%Y%m%d-%H%M%S)"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this script as root on the analytics server." >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR" /etc/prometheus/rules /etc/grafana/provisioning/datasources \
  /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards \
  /etc/systemd/system/grafana-server.service.d

backup_file() {
  path=$1
  if [ -f "$path" ]; then
    mkdir -p "$BACKUP_DIR$(dirname "$path")"
    cp -p "$path" "$BACKUP_DIR$path"
  fi
}

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y prometheus prometheus-node-exporter apt-transport-https wget gnupg
  if ! apt-cache show grafana >/dev/null 2>&1; then
    install -d -m 0755 /etc/apt/keyrings
    wget -q -O /etc/apt/keyrings/grafana.asc https://apt.grafana.com/gpg-full.key
    chmod 0644 /etc/apt/keyrings/grafana.asc
    printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main' \
      > /etc/apt/sources.list.d/grafana.list
    apt-get update
  fi
  apt-get install -y grafana
else
  echo "Automatic server package installation currently supports Debian/Ubuntu (apt)." >&2
  exit 1
fi

for path in \
  /etc/prometheus/prometheus.yml \
  /etc/prometheus/rules/openwrt-recording-rules.yml \
  /etc/default/prometheus \
  /etc/grafana/provisioning/datasources/prometheus.yml \
  /etc/grafana/provisioning/dashboards/openwrt-network-analytics.yml \
  /etc/systemd/system/grafana-server.service.d/openwrt-analytics.conf \
  /etc/grafana/provisioning/dashboards/firewall-analytics.yml; do
  backup_file "$path"
done

install -o root -g root -m 0644 "$BUILD_DIR/prometheus.yml" /etc/prometheus/prometheus.yml
install -o root -g root -m 0644 "$BUILD_DIR/openwrt-recording-rules.yml" /etc/prometheus/rules/openwrt-recording-rules.yml
install -o root -g root -m 0644 "$BUILD_DIR/prometheus-defaults" /etc/default/prometheus
install -o root -g grafana -m 0644 "$BUILD_DIR/grafana-datasource.yml" /etc/grafana/provisioning/datasources/prometheus.yml
install -o root -g grafana -m 0644 "$BUILD_DIR/grafana-dashboard-provider.yml" /etc/grafana/provisioning/dashboards/openwrt-network-analytics.yml
install -o root -g root -m 0644 "$BUILD_DIR/grafana-openwrt-analytics.conf" /etc/systemd/system/grafana-server.service.d/openwrt-analytics.conf
# Remove the pre-project provider after backing it up. Keeping both files makes
# Grafana provision every dashboard UID twice and serve stale dashboard copies.
rm -f /etc/grafana/provisioning/dashboards/firewall-analytics.yml
for dashboard in "$BUILD_DIR"/*dashboard.json; do
  backup_file "/var/lib/grafana/dashboards/$(basename "$dashboard")"
  install -o grafana -g grafana -m 0644 "$dashboard" /var/lib/grafana/dashboards/
done

promtool check config /etc/prometheus/prometheus.yml
promtool check rules /etc/prometheus/rules/openwrt-recording-rules.yml
systemctl daemon-reload
systemctl enable prometheus prometheus-node-exporter grafana-server
systemctl restart prometheus prometheus-node-exporter grafana-server
echo "Server installation complete. Backup: $BACKUP_DIR"

#!/bin/sh
set -eu

PAYLOAD=${1:?usage: install-router.sh PAYLOAD_DIR LAN_CIDR}
LAN_CIDR=${2:?usage: install-router.sh PAYLOAD_DIR LAN_CIDR}
BACKUP="/root/openwrt-network-analytics-backup-$(date +%Y%m%d-%H%M%S)"

[ "$(id -u)" -eq 0 ] || { echo "Run as root on OpenWrt." >&2; exit 1; }
mkdir -p "$BACKUP"
# shellcheck source=/dev/null
. "$PAYLOAD/site.env"

opkg update
opkg install nlbwmon netifyd socat coreutils-install coreutils-timeout prometheus-node-exporter-lua \
  prometheus-node-exporter-lua-ethtool prometheus-node-exporter-lua-hwmon \
  prometheus-node-exporter-lua-mwan3 prometheus-node-exporter-lua-nat_traffic \
  prometheus-node-exporter-lua-netstat prometheus-node-exporter-lua-nft-counters \
  prometheus-node-exporter-lua-openwrt prometheus-node-exporter-lua-thermal

for path in /etc/config/nlbwmon /etc/config/netifyd /etc/config/prometheus-node-exporter-lua \
  /etc/netifyd.conf /etc/nftables.d/90-openwrt-network-analytics-apps.nft \
  /etc/nftables.d/90-prometheus-wan-apps.nft \
  /etc/nftables.d/91-openwrt-network-analytics-devices.nft \
  /etc/nftables.d/91-prometheus-wan-devices.nft /etc/prometheus-device-names \
  /etc/init.d/prometheus-netify-stream; do
  [ ! -e "$path" ] || cp -p "$path" "$BACKUP/$(basename "$path")"
done

if ! uci -q get nlbwmon.@nlbwmon[0] >/dev/null; then uci add nlbwmon nlbwmon >/dev/null; fi
uci set nlbwmon.@nlbwmon[0].netlink_buffer_size='4194304'
uci set nlbwmon.@nlbwmon[0].commit_interval='24h'
uci set nlbwmon.@nlbwmon[0].refresh_interval='30s'
uci set nlbwmon.@nlbwmon[0].database_directory='/var/lib/nlbwmon'
uci set nlbwmon.@nlbwmon[0].database_generations='12'
uci set nlbwmon.@nlbwmon[0].database_interval='1'
uci set nlbwmon.@nlbwmon[0].database_limit='0'
uci -q delete nlbwmon.@nlbwmon[0].local_network || true
uci add_list nlbwmon.@nlbwmon[0].local_network="$LAN_CIDR"
uci add_list nlbwmon.@nlbwmon[0].local_network='lan'
uci commit nlbwmon

uci set prometheus-node-exporter-lua.main.listen_interface='lan'
uci set prometheus-node-exporter-lua.main.listen_port="$ROUTER_EXPORTER_PORT"
uci commit prometheus-node-exporter-lua

uci set netifyd.@netifyd[0].enabled='1'
uci set netifyd.@netifyd[0].autoconfig='0'
uci set netifyd.@netifyd[0].internal_if="$LAN_DEVICE"
uci -q delete netifyd.@netifyd[0].external_if || true
# Intentional word splitting: the rendered value is a validated space-separated list.
# shellcheck disable=SC2086
for device in $WAN_DEVICES; do uci add_list netifyd.@netifyd[0].external_if="$device"; done
uci commit netifyd

install -d -m 0755 /usr/lib/lua/prometheus-collectors /etc/nftables.d
for collector in nlbwmon netify device_inventory wan_apps wan_devices; do
  install -m 0644 "$PAYLOAD/$collector.lua" "/usr/lib/lua/prometheus-collectors/$collector.lua"
done
install -m 0644 "$PAYLOAD/netify-stream.lua" /usr/lib/lua/prometheus-netify-stream.lua
rm -f /usr/lib/lua/prometheus-collectors/netify-stream.lua
install -m 0755 "$PAYLOAD/prometheus-netify-stream" /usr/bin/prometheus-netify-stream
install -m 0755 "$PAYLOAD/prometheus-netify-stream.init" /etc/init.d/prometheus-netify-stream
install -m 0755 "$PAYLOAD/device-name" /usr/bin/device-name
install -m 0755 "$PAYLOAD/prometheus-device-names-refresh" /usr/bin/prometheus-device-names-refresh
install -m 0755 "$PAYLOAD/prometheus-device-inventory-checkpoint" /usr/bin/prometheus-device-inventory-checkpoint
install -m 0644 "$PAYLOAD/netifyd.conf" /etc/netifyd.conf
install -m 0644 "$PAYLOAD/wan_app_counters.nft" /etc/nftables.d/90-openwrt-network-analytics-apps.nft
install -m 0644 "$PAYLOAD/90-prometheus-wan-devices.nft" /etc/nftables.d/91-openwrt-network-analytics-devices.nft
[ -f /etc/prometheus-device-names ] || install -m 0600 "$PAYLOAD/prometheus-device-names" /etc/prometheus-device-names

# Migrate the pre-project filename after preserving it in the timestamped backup.
# Keeping both files would define the same nftables meters twice and fail fw4.
rm -f /etc/nftables.d/90-prometheus-wan-apps.nft
rm -f /etc/nftables.d/91-prometheus-wan-devices.nft

grep -q 'prometheus-device-names-refresh' /etc/crontabs/root 2>/dev/null || \
  echo '*/5 * * * * /usr/bin/prometheus-device-names-refresh >/dev/null 2>&1' >> /etc/crontabs/root
grep -q 'prometheus-device-inventory-checkpoint' /etc/crontabs/root 2>/dev/null || \
  echo '*/5 * * * * /usr/bin/prometheus-device-inventory-checkpoint >/dev/null 2>&1' >> /etc/crontabs/root

# `fw4 check` evaluates against the active table and falsely reports duplicate
# named meters during upgrades. Compile the generated ruleset under an isolated
# table name instead, then reload only after the complete ruleset is valid.
fw4 print | sed 's/table inet fw4/table inet fw4_validate/g' | nft -c -f -
nft delete chain inet fw4 prometheus_wan_devices 2>/dev/null || true
sed -n 's/.* meter \([^ ]*\) .*/\1/p' /etc/nftables.d/91-openwrt-network-analytics-devices.nft | \
  sort -u | while IFS= read -r meter_name; do
    nft delete set inet fw4 "$meter_name" 2>/dev/null || true
  done
/etc/init.d/firewall reload
for service in nlbwmon netifyd prometheus-netify-stream cron prometheus-node-exporter-lua; do
  "/etc/init.d/$service" enable
  "/etc/init.d/$service" restart
done
/usr/bin/prometheus-device-names-refresh || true
/usr/bin/prometheus-device-inventory-checkpoint || true
echo "Router installation complete. Backup: $BACKUP"

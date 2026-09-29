# Architecture

```text
LAN clients -> OpenWrt/fw4
                 |-- nlbwmon: aggregated per-device counters
                 |-- nftables: forwarded upload/download totals per WAN
                 |-- mwan3 and system collectors
                 |-- Lua exporter :9100
                          |
                          v
                 Prometheus on server
                          |
                          v
                    Grafana :3000
```

The stack deliberately separates two scopes:

- `openwrt_wan_bytes_total` counts forwarded traffic on each configured WAN
  with passive nftables counters. Router-originated WAN traffic is excluded by
  the `forward` hook.
- `nlbwmon_*` counters provide LAN-device traffic totals aggregated by address
  family, MAC, and IP.

WAN interface counters provide an independent reference for rates and
reconciliation. Minor differences between interface, forwarded-WAN, and
per-device totals are expected because they observe different boundaries.

The nlbwmon exporter intentionally removes transport port, protocol, and
Layer-7 labels before exporting. This keeps the series count bounded and
prevents unreliable application guesses from being retained in Prometheus.
The project does not run Netify, collect SNI, correlate visited hostnames, or
classify applications and services.

Device names come from OpenWrt host hints, DHCP leases, optional configured DNS
PTR lookups, and manual MAC aliases. These are device identity names, not
destination hostnames or DNS-query logs.

Configuration is rendered into `build/` from the tracked templates in
`monitoring/`. Tokens are replaced using `config.env`; local configuration,
credentials, aliases, backups, and rendered output are ignored by Git.

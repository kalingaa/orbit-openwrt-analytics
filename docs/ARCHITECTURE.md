# Architecture

```text
LAN clients -> OpenWrt/fw4
                 |-- nlbwmon: device counters
                 |-- netifyd: local application classification
                 |-- nftables: WAN/device counters
                 |-- Lua exporter :9100
                          |
                          v
                 Prometheus on server
                          |
                          v
                    Grafana :3000
```

Interface counters are authoritative for total WAN usage. `nlbwmon` provides
device accounting. Netify provides best-effort application attribution. The
data-quality dashboard deliberately compares these different scopes rather
than implying that they must match exactly.

Configuration is rendered into `build/` from the tracked templates in
`monitoring/`. Tokens are replaced using `config.env`; local configuration,
credentials, aliases, and rendered output are ignored by Git.

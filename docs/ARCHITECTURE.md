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

The Netify collector preserves four different concepts instead of treating a
transport as an application:

- `application`: a Netify DPI application, or `Unknown`.
- `service` and `domain`: a bounded service name or base domain derived from
  visible DNS hints, HTTP host metadata, TLS SNI, or QUIC metadata.
- `protocol`: the underlying protocol, such as HTTPS, QUIC, or WireGuard.
- `traffic_class`: application, VPN, encrypted DNS, Tor, proxy, unresolved
  QUIC, or unclassified.

Netify intelligence indicators take priority when the installed agent exposes
them. Otherwise, the collector uses DPI names, visible hostnames, and a small
conservative protocol/service ruleset. It never decrypts payloads. ECH,
obfuscated tunnels, and shared hosting can still prevent attribution.

Configuration is rendered into `build/` from the tracked templates in
`monitoring/`. Tokens are replaced using `config.env`; local configuration,
credentials, aliases, and rendered output are ignored by Git.

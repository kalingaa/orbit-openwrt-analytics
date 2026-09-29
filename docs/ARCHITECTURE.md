# Architecture

```text
LAN clients -> OpenWrt/fw4
                 |-- nlbwmon: device counters
                 |-- netifyd: local application classification
                 |      `-- Unix event stream -> persistent interval collector
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

Application byte accounting consumes Netify's Unix socket continuously. A
`flow` record supplies device and DPI metadata, while `flow_stats` and
`flow_purge` records supply directional byte intervals. The collector joins
those records by flow digest, deduplicates repeated events, backfills metadata
for already-active flows from Netify's local snapshot, and stores monotonic
Prometheus counters in tmpfs. Runtime flow metadata expires after five minutes
and is never written to the exported state file; only compact cumulative
counters are flushed every five seconds. This keeps the Unix socket consumer
ahead of Netify's event producer and prevents an in-memory socket backlog. If
the event consumer is unavailable, the Lua
exporter temporarily falls back to the older active-flow snapshot method and
sets `openwrt_netify_stream_up` to zero.

A five-minute memory guard restarts only the passive `netifyd` DPI service if
its resident memory exceeds 512 MiB. Packet forwarding, firewall state, WANs,
DNS, DHCP, and VPN services are unaffected by this defensive restart.

Per-device application accounting accepts `local_ip` values only when they are
inside the configured `LAN_CIDR`. This boundary check is intentional: Netify
can describe router and upstream gateway addresses as local when observing a
WAN interface. Those records are rejected and any cached non-LAN totals are
removed, so device views represent LAN-originated traffic routed to a WAN.
The installer configures the LAN capture device as a UCI list because the
OpenWrt Netify init script consumes both internal and external interfaces with
`config_list_foreach`.

OpenWrt's packaged Netify v4 agent is a DPI classifier, not an authoritative
traffic-accounting engine. It may stop reporting byte growth after its packet
inspection budget is reached even though the connection continues. The
application dashboards therefore label these values as *DPI-attributed* and
show total WAN bytes, unattributed bytes, and coverage separately. They never
scale sampled application values to manufacture a 100% attribution result.

The nftables exporter deliberately exposes two separate metric families:

- `openwrt_wan_bytes_total` is the authoritative passive WAN total.
- `openwrt_wan_port_application_bytes_total` contains overlapping port-based
  classifications such as HTTPS, QUIC, and DNS.

The second family must not be summed to calculate WAN totals. A packet can be
present in both the WAN total and one port classification by design.

Per-device WAN panels use LAN-filtered Netify attribution. Earlier releases
used inline named nftables meters for these panels. Those meters were removed
because OpenWrt evaluates custom includes against the active `fw4` table on
every interface reload; meter-name collisions could abort a WAN `ifup` reload
and leave routing/NAT in an incomplete boot-time state.

The Netify collector preserves four different concepts instead of treating a
transport as an application:

- `application`: the best resolved display name, preferring Netify DPI and then
  a hostname-derived service/base domain. This keeps existing application
  dashboards useful without ever substituting a transport such as QUIC.
- `dpi_application`: the strict Netify DPI application, or `Unknown`.
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

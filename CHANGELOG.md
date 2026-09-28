# Changelog

All notable changes are documented here. This project follows Semantic
Versioning once the first tagged release is published.

## 0.1.0 - Unreleased

- Initial reusable OpenWrt, Prometheus, and Grafana analytics stack.
- Keep QUIC and HTTPS as protocols instead of fallback applications.
- Add service/base-domain attribution and VPN, encrypted-DNS, Tor, proxy, and
  unresolved-QUIC traffic classes.
- Add Service & Security Analytics plus per-device and per-WAN service panels.
- Make OpenWrt upgrades compatible with Dropbear legacy SCP, minimal images
  without `install`, and reloads of existing named nftables device meters.
- Discover and deduplicate Netify flows across bridge and physical capture
  interfaces instead of assuming one snapshot key.
- Keep existing application dashboards useful by exposing the best resolved
  application/service name while retaining strict DPI results separately.
- Replace lossy active-flow snapshot accounting with a persistent Netify event
  consumer that joins flow metadata to periodic and final directional bytes.
- Separate authoritative nftables WAN totals from overlapping port-based
  application counters so totals cannot accidentally be summed twice.
- Remove the legacy WAN-application nftables include during upgrades so fw4
  cannot append a second identical set of accounting rules.
- Show authoritative WAN usage, unattributed bytes, application coverage, and
  Netify stream health directly in Grafana.
- Restrict per-device application accounting to `LAN_CIDR` and purge cached
  WAN-side/router addresses from device series.
- Configure Netify's internal interface as the UCI list expected by its init
  script, ensuring the daemon actually starts with LAN capture enabled.
- Filter application device panels by the rendered LAN CIDR so historical
  WAN-side samples are hidden immediately as well as rejected going forward.
- Remove inline named per-device nftables meters that could collide during
  `fw4` reloads and break post-reboot WAN forwarding; WAN device panels now use
  LAN-filtered Netify attribution.
- Ensure OpenWrt selects `ip-full` for mwan3 so policy routes using blackhole,
  unreachable, and mark syntax are built correctly after boot.
- Remove the legacy duplicate Grafana dashboard provider during upgrades so
  each dashboard UID is provisioned once and current panels are served.
- Keep fresh Netify scrapes below the detail-job timeout by skipping fallback
  conntrack and label work while the event stream is healthy.
- Query reload-safe forwarded-WAN counters directly for all WAN usage cards,
  avoiding an unnecessary interface-label join.
- Isolate high-cardinality Netify serialization in a dedicated 10-second
  scrape so it cannot time out the fast WAN, mwan3, inventory, and nlbwmon
  collectors.
- Bound Netify flow metadata to 15 minutes, discard purged-flow state
  immediately, and reset the ephemeral accumulator during upgrades to prevent
  router memory exhaustion.
- Ensure the Netify stream wrapper terminates its Lua and socket children so
  service restarts cannot leave high-memory orphan collectors behind.
- Raise the OpenWrt kernel receive-buffer ceiling for reliable nlbwmon
  conntrack dumps.
- Correct rendered LAN-regex escaping, validate it during tests, and use safer
  dashboard refresh intervals for expensive or long-range queries. Grafana
  also enforces a 30-second minimum for refresh values retained in old URLs.
- Evaluate rolling 24-hour recording rules hourly so daily panels recover
  promptly after Prometheus restarts.
- Guided configuration and one-command rendering/deployment workflow.
- Support for one to three WANs and optional external DNS hostname lookup.
- Eight provisioned dashboards covering overview, devices, WANs, applications,
  long-term rollups, inventory, and collector data quality.
- Health, backup, upgrade, and conservative uninstall workflows.
- Public-release privacy guardrails and automated validation workflow.

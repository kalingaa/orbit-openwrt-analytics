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
- Guided configuration and one-command rendering/deployment workflow.
- Support for one to three WANs and optional external DNS hostname lookup.
- Eight provisioned dashboards covering overview, devices, WANs, applications,
  long-term rollups, inventory, and collector data quality.
- Health, backup, upgrade, and conservative uninstall workflows.
- Public-release privacy guardrails and automated validation workflow.

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
- Guided configuration and one-command rendering/deployment workflow.
- Support for one to three WANs and optional external DNS hostname lookup.
- Eight provisioned dashboards covering overview, devices, WANs, applications,
  long-term rollups, inventory, and collector data quality.
- Health, backup, upgrade, and conservative uninstall workflows.
- Public-release privacy guardrails and automated validation workflow.

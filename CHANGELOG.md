# Changelog

All notable changes are documented here. This project follows Semantic
Versioning once the first tagged release is published.

## 0.1.0 - Unreleased

- Initial reusable OpenWrt, Prometheus, and Grafana analytics stack.
- Remove Netify, DPI, SNI/hostname correlation, port-based application
  counters, application/service dashboards, and their high-cardinality labels.
- Aggregate nlbwmon metrics by address family, MAC, and IP before export to
  reduce router and Prometheus overhead.
- Count only forwarded upload/download totals on each WAN; router-originated
  WAN traffic is excluded.
- Ensure OpenWrt selects `ip-full` for mwan3 so policy routes using blackhole,
  unreachable, and mark syntax are built correctly after boot.
- Remove the legacy duplicate Grafana dashboard provider during upgrades so
  each dashboard UID is provisioned once and current panels are served.
- Query reload-safe forwarded-WAN counters directly for all WAN usage cards,
  avoiding an unnecessary interface-label join.
- Raise the OpenWrt kernel receive-buffer ceiling for reliable nlbwmon
  conntrack dumps.
- Use safer dashboard refresh intervals for expensive or long-range queries.
  Grafana also enforces a 30-second minimum for refresh values retained in old
  URLs.
- Evaluate rolling 24-hour recording rules hourly so daily panels recover
  promptly after Prometheus restarts.
- Guided configuration and one-command rendering/deployment workflow.
- Support for one to three WANs and optional external DNS hostname lookup.
- Six provisioned dashboards covering overview, devices, WANs, long-term
  rollups, inventory, and collector data quality.
- Health, backup, upgrade, and conservative uninstall workflows.
- Public-release privacy guardrails and automated validation workflow.
